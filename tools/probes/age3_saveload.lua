-- Phase 5 M3 age3 save/load probe (test copy only; docs/qa/phase5-age3-notes.md):
--   SAVE_MINUTE=3 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/age3_saveload.lua tools/saveload-check.sh p5m3-age3-sl \
--     '{opponents = 1, difficulty = "normal", mode = "nation", enemy_brain = "ai"}' 200
-- At match minute 1 rts-player gets Age II and Electrification, starts the Space Program with half of stage 1 in its
-- network and rushes it, gets gold into its capital every 10 s, hires 8 garrison points and buys from a city-state; the
-- server saves at minute 3 and the loaded game runs on. At minute 4 the rest of stage 1 arrives; at minute 5 the probe
-- checks Age III, the Launch complex label, the gold bonus, the hired points and the delivery. Log lines
-- "[rts] age3 sl <check>: PASS|FAIL ..." (in the loaded server's log).
local events = require("scripts.events")
local util = require("scripts.util")
local research = require("scripts.research")
local ages = require("scripts.ages")
local cities = require("scripts.cities")
local garrison = require("scripts.garrison")
local treasury = require("scripts.treasury")
local age3 = require("scripts.age3")
local rare = require("scripts.rare")
local sinks = require("scripts.sinks")
local balance = require("balance")

local F = util.PLAYER_FORCE
local A3 = balance.nation.age3

local function check(name, ok, fmt, ...)
  util.log("age3 sl %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function research_now(tech)
  local t = game.forces[F].technologies[tech]
  if t and not t.researched then t.researched = true end
  research.apply(game.forces[F])
end

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = storage.a3sl or {step = "wait"}
  storage.a3sl = s
  local age = e.tick - m.tick_started
  local net = rare.capital_network(F)
  if s.feed and net and age % 600 == 0 then net.insert({name = "rts-rare-gold", count = 1}) end
  if s.step == "wait" and age >= 60 * 60 then
    research_now("rts-industrialisation")
    ages.set_age(F, 2, "saveload probe")
    research_now(A3.tech)
    treasury.set_balance(F, 10000, "saveload probe")
    local P = age3.start(F)
    for item, n in pairs(A3.stages[1].required) do net.insert({name = item, count = math.floor(n / 2)}) end
    local ok = sinks.rush(F, "project")
    s.feed = true
    s.city = storage.nations[F].capital
    local hired = sinks.hire_garrison(F, s.city, 8)
    local bought
    for _, cs in ipairs(sinks.city_states(F)) do
      for _, g in ipairs(cs.goods) do
        if not bought and g.stock >= 10 then
          bought = sinks.trade_with_city_state(F, cs.city_id, g.item, 10, true) and g.item
        end
      end
    end
    s.item = bought or nil
    s.item0 = bought and net.get_item_count(bought) or 0
    util.log("age3 sl: set up at tick %d: program %s, rush %s, hired %s, bought %s", e.tick, P and P.state or "nil",
      tostring(ok), tostring(hired), tostring(bought))
    s.step = "rest"
  elseif s.step == "rest" and age >= 4 * 3600 then
    for item, n in pairs(A3.stages[1].required) do net.insert({name = item, count = n}) end -- (the AI uses steel too)
    s.step = "check"
  elseif s.step == "check" and age >= 5 * 3600 then
    local P = age3.project(F)
    local r = storage.age3.render[F]
    check("program", ages.of(F) == 3 and P and P.stage == 2 and r and r.text and r.text.valid,
      "after the load: age %d, program stage %s %s, label %s", ages.of(F), P and P.stage or "-", P and P.state or "-",
      tostring(r and r.text and r.text.valid))
    check("gold", treasury.tax_bonus(F) == 0.15 and rare.bonuses(F).gold.active, "gold bonus %.2f",
      treasury.tax_bonus(F))
    local g = garrison.of(s.city)
    check("hired", (g.hired or 0) > 0 and (g.hired or 0) < 8 and (g.turrets or 0) == math.floor(g.points / 4 + 1e-6),
      "hired points %.2f (all points %.2f), turrets %d", g.hired or 0, g.points or 0, g.turrets or 0)
    check("delivery", #storage.sinks.pending == 0, "city-state purchase of %s delivered (pending %d)", tostring(s.item),
      #storage.sinks.pending)
    util.log("age3 sl: %s | %s | %s", age3.describe(F), rare.describe(F), sinks.describe(F))
    s.step = "done"
  end
end)
