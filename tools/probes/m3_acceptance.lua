-- Phase 5 M3 end-to-end acceptance helper (docs/PHASE5-M3.md section 4 "M3 end-to-end"; docs/qa/phase5-m3-integration-
-- notes.md). Test-only module for tools/autotest-run.sh (EXTRA_LUA) on a 4-nation Nation match of normal AIs:
--   PERF=1 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m3_acceptance.lua DURATION_MIN=60 SEED=801 SPEED=8 \
--     tools/autotest-run.sh m3acc-801 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
--     enemy_brain = "ai"}' 10000
-- It keeps the M2 criteria of tools/probes/m2_acceptance.lua (trade, war, peace, capture, starving; the last
-- FINAL_MINUTES at speed 1, so the AI autotest's minute lines of those minutes measure UPS) and adds the non-AI M3
-- measurements of the integration (balance pass, docs/qa/phase5-m3-integration-notes.md section A):
--   treasury   per nation the lowest balance, the highest debt stage, minutes in debt, the credit line reached
--              ("bankrupt"), tax switches (market.lua's AI tax log)
--   rails      per nation the first line open (minute), lines open now, items by train; capital depots destroyed
--   ages       Age II and Age III times, the Space Program stage, Space victory
--   M3         rushes, hired points, mercenaries, city-state trade, rare bonuses, automation kits, planes, belts,
--              artillery shots, fronts (the modules' describe lines every 10 minutes)
-- Log: "[rts] m3 acceptance minute N: ..." every 10 minutes, per nation "[rts] m3 acceptance nation <force>: ..." and
--   "[rts] m3 acceptance check <name>: PASS|FAIL ..." at the end, then "[rts] m3 acceptance summary ...".
local events = require("scripts.events")
local util = require("scripts.util")
local autotest = require("scripts.ai.autotest")
local match = require("scripts.match")

local FINAL_MINUTES = 5
local STARVE_MINUTES = 3
local LINE_GOAL_MIN = 25 -- integration goal: every nation's first line open before minute 25 (informational)

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function A()
  local a = storage.m3acc
  if not a then
    a = {declared = 0, ended = 0, peace = 0, captures = 0, nation_captures = 0, cs_captures = 0, treaties = {},
         hunger = {}, starving = {}, log = {}, nat = {}, depots_lost = {}, space = nil}
    storage.m3acc = a
  end
  return a
end

local function minute_of()
  local m = storage.match
  return (m and m.tick_started) and math.floor((game.tick - m.tick_started) / 3600) or 0
end

local function mtime()
  local m = storage.match
  local t = (m and m.tick_started) and (game.tick - m.tick_started) or 0
  return string.format("%d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60)
end

local function nations()
  local out = {}
  for _, f in ipairs(match.forces()) do out[#out + 1] = f end
  return out
end

local function NAT(f)
  local a = A()
  local n = a.nat[f]
  if not n then
    n = {min_balance = nil, max_stage = 0, debt_ticks = 0, credit_hit = nil, line_at = nil, age2 = nil, age3 = nil,
         stage_at = {}}
    a.nat[f] = n
  end
  return n
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
events.on_signal("rts_treasury_stage", function(d)
  local n = NAT(d.force)
  if d.stage > n.max_stage then
    n.max_stage = d.stage
    n.stage_at[d.stage] = mtime()
  end
end)
events.on_signal("rts_space_victory", function(d)
  local a = A()
  a.space = string.format("%s at %s", tostring(d.force), mtime())
  a.log[#a.log + 1] = string.format("%d:space %s", minute_of(), tostring(d.force))
end)

-- a capital depot destroyed (M1 acceptance train goal: an AI razed the player's capital depot at minute 36)
events.on(defines.events.on_entity_died, function(e)
  local ent = e.entity
  if not (ent and ent.valid and ent.name == "rts-depot") then return end
  local territory, cities = mod("territory"), mod("cities")
  local cid = territory and territory.city_at(ent.position)
  local c = cid and cities and cities.get(cid)
  local is_cap = c and c.capital
  local by = e.force and e.force.name or "?"
  local a = A()
  a.depots_lost[#a.depots_lost + 1] = string.format("%s %s%s by %s", mtime(), ent.force.name,
    is_cap and " (capital)" or "", by)
  util.log("m3 acceptance: depot of %s destroyed at %s%s by %s", ent.force.name, mtime(), is_cap and " (capital)" or "",
    by)
end)

-- every second: treasury, first open line, ages
local function poll()
  local treasury, rails, ages = mod("treasury"), mod("rails"), mod("ages")
  for _, f in ipairs(nations()) do
    local n = NAT(f)
    local N = storage.treasury and storage.treasury[f]
    if N then
      if not n.min_balance or N.balance < n.min_balance then n.min_balance = N.balance; n.min_at = mtime() end
      if N.balance < 0 then n.debt_ticks = n.debt_ticks + 60 end
      local credit = N.credit or 500
      if N.balance <= -credit and not n.credit_hit then n.credit_hit = mtime() end
    end
    if not n.line_at and rails then
      for _, line in ipairs(rails.lines_of(f) or {}) do
        if line.state == "open" then n.line_at = mtime(); n.line_min = minute_of(); break end
      end
    end
    if ages then
      local age = ages.of(f)
      if age >= 2 and not n.age2 then n.age2 = mtime() end
      if age >= 3 and not n.age3 then n.age3 = mtime() end
    end
  end
end

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
          util.log("m3 acceptance: %s starving: %s", f, a.starving[f])
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

local DESCRIBE = {"age3", "rare", "sinks", "air", "belts", "trainswar", "fronts"}

local function m3_lines(n)
  for _, f in ipairs(nations()) do
    local parts = {}
    for _, name in ipairs(DESCRIBE) do
      local M = mod(name)
      if M and M.describe then
        local ok, s = pcall(M.describe, f)
        if ok and s then parts[#parts + 1] = (tostring(s):gsub("^" .. f .. ": ", "")) end
      end
    end
    util.log("m3 acceptance minute %d %s m3: %s", n, f, table.concat(parts, " | "))
  end
end

local function nation_line(f)
  local n = NAT(f)
  local rails, market = mod("rails"), mod("market")
  local rs = rails and rails.stats(f)
  local open = 0
  for _, line in ipairs(rails and rails.lines_of(f) or {}) do
    if line.state == "open" then open = open + 1 end
  end
  local N = storage.treasury and storage.treasury[f]
  local switches = market and storage.market and storage.market.ai and storage.market.ai[f]
    and storage.market.ai[f].tax_switches
  util.log("m3 acceptance nation %s: Age II %s, Age III %s, first line %s, lines open %d, items by train %d | "
    .. "balance now %s, lowest %s at %s, highest debt stage %d%s, %.1f min in debt, credit line %s, tax switches %s",
    f, n.age2 or "-", n.age3 or "-", n.line_at or "-", open, rs and rs.items or 0,
    N and string.format("%.0f", N.balance) or "-", n.min_balance and string.format("%.0f", n.min_balance) or "-",
    n.min_at or "-", n.max_stage, n.stage_at[n.max_stage] and (" at " .. n.stage_at[n.max_stage]) or "",
    n.debt_ticks / 3600, n.credit_hit or "never", tostring(switches or "-"))
end

local function final()
  local a = A()
  if a.final then return end
  a.final = true
  local vol, all_trade = volumes()
  local function check(name, ok, fmt, ...)
    util.log("m3 acceptance check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
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
  local debt, bankrupt, late = {}, {}, {}
  for _, f in ipairs(nations()) do
    nation_line(f)
    local n = NAT(f)
    if n.max_stage >= 1 then debt[#debt + 1] = f .. " " .. n.max_stage end
    if n.credit_hit then bankrupt[#bankrupt + 1] = f .. " " .. n.credit_hit end
    if not n.line_min or n.line_min >= LINE_GOAL_MIN then late[#late + 1] = f .. " " .. (n.line_at or "none") end
  end
  check("debt", #debt >= 1, "nations in a debt stage: %s (seed criterion: >= 1 in >= 2 of 5 seeds)",
    #debt > 0 and table.concat(debt, ", ") or "none")
  check("bankrupt", #bankrupt == 0, "nations at the credit line: %s", #bankrupt > 0 and table.concat(bankrupt, ", ")
    or "none")
  check("lines", #late == 0, "first lines at or after minute %d: %s", LINE_GOAL_MIN,
    #late > 0 and table.concat(late, ", ") or "none")
  util.log("m3 acceptance summary: wars %d, peace %d, ended %d, captures %d (%d nation, %d city-state), trade [%s], "
    .. "cities [%s], space %s, depots lost [%s], events [%s]", a.declared, a.peace, a.ended, a.captures,
    a.nation_captures, a.cs_captures, vol, cities_line(), a.space or "none", table.concat(a.depots_lost, "; "),
    table.concat(a.log, " "))
end

events.on_nth_tick(60, function(e)
  local s = storage.ai_autotest
  if not s then return end
  poll()
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
      util.log("m3 acceptance minute %d: wars %d, peace %d, captures %d, trade [%s], cities [%s]", n, a.declared,
        a.peace, a.captures, (volumes()), cities_line())
      m3_lines(n)
      for _, f in ipairs(nations()) do nation_line(f) end
    end
  end
  -- just before the autotest's end (its summary ends the run)
  if (s.done or age >= autotest.DURATION - 120) then final() end
end)
