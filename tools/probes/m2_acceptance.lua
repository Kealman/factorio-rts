-- Phase 5 M2 end-to-end acceptance helper (docs/PHASE5-M2.md section 4 "M2 end-to-end"; docs/qa/phase5-m2-integration-
-- notes.md). Test-only module for tools/autotest-run.sh (EXTRA_LUA) on a 4-nation Nation match of normal AIs:
--   PERF=1 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m2_acceptance.lua DURATION_MIN=60 SEED=701 SPEED=8 \
--     tools/autotest-run.sh m2acc-701 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
--     enemy_brain = "ai"}' 9000
-- Like tools/probes/m1_acceptance.lua it switches the game to speed 1 for the last FINAL_MINUTES, so the AI autotest's
-- "ai perf minute N ... wall clock" lines of those minutes measure UPS at speed 1. It also records, for the per-seed
-- criteria of the contract:
--   trade      every nation's market volume (market.volume(f).total > 0 at the end)
--   wars       wars declared (signal rts_war_declared), wars ended in a treaty (rts_war_ended) and pairs that went from
--              war or ceasefire to peace (rts_diplomacy_changed)
--   captures   cities that changed hands (rts_city_captured): between nations, and city-states taken
--   starving   a city below 50 % rations for more than STARVE_MINUTES minutes in a row (per nation)
-- Log: "[rts] m2 acceptance minute N: ..." every 10 minutes and the final lines
--   "[rts] m2 acceptance check <trade|war|peace|capture|starving>: PASS|FAIL ..." and "[rts] m2 acceptance summary ...".
local events = require("scripts.events")
local util = require("scripts.util")
local autotest = require("scripts.ai.autotest")
local match = require("scripts.match")

local FINAL_MINUTES = 5
local STARVE_MINUTES = 3

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function A()
  local a = storage.m2acc
  if not a then
    a = {declared = 0, ended = 0, peace = 0, captures = 0, nation_captures = 0, cs_captures = 0, treaties = {},
         hunger = {}, starving = {}, log = {}}
    storage.m2acc = a
  end
  return a
end

local function minute_of()
  local m = storage.match
  return (m and m.tick_started) and math.floor((game.tick - m.tick_started) / 3600) or 0
end

events.on_signal("rts_war_declared", function(d)
  local a = A()
  a.declared = a.declared + 1
  a.log[#a.log + 1] = string.format("%d:war#%s", minute_of(), tostring(d.war_id))
end)
events.on_signal("rts_war_ended", function(d)
  local a = A()
  a.ended = a.ended + 1
  local k = d.treaty and d.treaty.kind or "white"
  a.treaties[k] = (a.treaties[k] or 0) + 1
  a.log[#a.log + 1] = string.format("%d:end#%s(%s)", minute_of(), tostring(d.war_id), k)
end)
events.on_signal("rts_diplomacy_changed", function(d)
  if d.state == "peace" and (d.old == "war" or d.old == "ceasefire") then
    local a = A()
    a.peace = a.peace + 1
    a.log[#a.log + 1] = string.format("%d:peace %s/%s", minute_of(), tostring(d.a), tostring(d.b))
  end
end)
events.on_signal("rts_city_captured", function(d)
  local a = A()
  a.captures = a.captures + 1
  if d.from == "rts-neutral" then a.cs_captures = a.cs_captures + 1 else a.nation_captures = a.nation_captures + 1 end
  a.log[#a.log + 1] = string.format("%d:city %s %s->%s", minute_of(), tostring(d.city_id), tostring(d.from),
    tostring(d.to))
end)

local function nations()
  local out = {}
  for _, f in ipairs(match.forces()) do out[#out + 1] = f end
  return out
end

-- once a minute: hunger per city
local function hunger_step()
  local a = A()
  local population, cities = mod("population"), mod("cities")
  if not (population and cities) then return end
  for _, f in ipairs(nations()) do
    for _, c in ipairs(cities.for_force(f)) do
      local P = population.of(c.id)
      local r = P and P.needs and P.needs["rts-rations"]
      local key = tostring(c.id)
      if r and r.met < 0.5 then
        a.hunger[key] = (a.hunger[key] or 0) + 1
        if a.hunger[key] > STARVE_MINUTES and not a.starving[f] then
          a.starving[f] = string.format("city %d at minute %d (%d%% rations for %d min)", c.id, minute_of(),
            math.floor(r.met * 100 + 0.5), a.hunger[key])
          util.log("m2 acceptance: %s starving: %s", f, a.starving[f])
        end
      else
        a.hunger[key] = 0
      end
    end
  end
end

local function volumes()
  local market = mod("market")
  local parts, all = {}, true
  for _, f in ipairs(nations()) do
    local v = market and market.volume(f) or {total = 0}
    parts[#parts + 1] = string.format("%s %.0f", f, v.total or 0)
    if not ((v.total or 0) > 0) then all = false end
  end
  return table.concat(parts, ", "), all
end

local function cities_line()
  local cities = mod("cities")
  local parts = {}
  for _, f in ipairs(nations()) do
    parts[#parts + 1] = string.format("%s %d", f, cities and #cities.for_force(f) or 0)
  end
  return table.concat(parts, ", ")
end

local function final()
  local a = A()
  if a.final then return end
  a.final = true
  local vol, all_trade = volumes()
  local function check(name, ok, fmt, ...)
    util.log("m2 acceptance check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
  end
  check("trade", all_trade, "volume (cr) %s", vol)
  check("war", a.declared >= 1, "%d wars declared", a.declared)
  check("peace", a.peace >= 1 or a.ended >= 1, "%d pairs back to peace, %d wars ended %s", a.peace, a.ended,
    serpent.line(a.treaties, {comment = false}))
  check("capture", a.captures >= 1, "%d cities changed hands (%d between nations, %d city-states)", a.captures,
    a.nation_captures, a.cs_captures)
  local starving = {}
  for f, why in pairs(a.starving) do starving[#starving + 1] = f .. ": " .. why end
  table.sort(starving)
  check("starving", #starving == 0, "%s", #starving == 0 and "no nation starving" or table.concat(starving, "; "))
  util.log("m2 acceptance summary: wars %d, peace %d, ended %d, captures %d (%d nation, %d city-state), trade [%s], "
    .. "cities [%s], events [%s]", a.declared, a.peace, a.ended, a.captures, a.nation_captures, a.cs_captures, vol,
    cities_line(), table.concat(a.log, " "))
end

events.on_nth_tick(60, function(e)
  local s = storage.ai_autotest
  if not s then return end
  local age = e.tick - s.started
  if not storage.m1_final_speed and age >= autotest.DURATION - FINAL_MINUTES * autotest.MINUTE then
    storage.m1_final_speed = true
    util.log("m1 acceptance: game speed %s -> 1 from minute %d (tick %d)", tostring(game.speed),
      math.floor(age / autotest.MINUTE), e.tick)
    game.speed = 1
  end
  if age > 0 and age % 3600 == 0 then
    hunger_step()
    local n = math.floor(age / 3600)
    if n % 10 == 0 then
      local a = A()
      util.log("m2 acceptance minute %d: wars %d, peace %d, captures %d, trade [%s], cities [%s]", n, a.declared,
        a.peace, a.captures, (volumes()), cities_line())
    end
  end
  -- just before the autotest's end (its summary ends the run)
  if (s.done or age >= autotest.DURATION - 120) then final() end
end)
