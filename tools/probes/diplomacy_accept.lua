-- Phase 5 M2 diplomacy acceptance (docs/PHASE5-M2.md §4 "Diplomacy/wars"; docs/qa/phase5-diplomacy-notes.md). Test-only
-- module for tools/autotest-run.sh (EXTRA_LUA) on a 4-nation Nation match. PROBE_MODE (set below or by sed):
--   "main"   initial states; a ceasefire pair deals no damage over 2 minutes with armies 30 tiles apart (then a war
--            control: the same armies fight); a war with goal "capture 1 city" ends in a treaty when the signal
--            "rts_city_captured" names that city; an AI declares war past its thresholds (relation nudged); a weary AI
--            accepts a ceasefire (and declines one while winning); Territory victory at 60 % for 3 minutes (needs
--            victory = "territory" in the match table)
--   "score"  Score victory at the time limit, shared with an ally (needs victory = "score")
-- Log: "[rts] dprobe check <name>: PASS|FAIL ...", "[rts] dprobe summary <pass>/<total>", stop marker "dprobe done".
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local match = require("scripts.match")
local diplomacy = require("scripts.diplomacy")
local wars = require("scripts.wars")
local territory = require("scripts.territory")
local orders = require("scripts.orders")
local ages = require("scripts.ages")

local PROBE_MODE = "main"

local P = {}
local function S()
  storage.dprobe = storage.dprobe or {pass = 0, fail = 0, step = 0}
  return storage.dprobe
end

local function check(name, ok, fmt, ...)
  local s = S()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("dprobe check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt or "", ...))
end

local function done()
  local s = S()
  if s.finished then return end
  s.finished = true
  util.log("dprobe summary %d/%d%s", s.pass, s.pass + s.fail, s.fail == 0 and " (all passed)" or " (FAILED)")
  log("[rts] dprobe done")
end

local function age_s()
  local m = storage.match
  return m and m.tick_started and (game.tick - m.tick_started) / 60 or 0
end

-- Probe armies: walkers claimed by this probe (orders.lua and the AI never command claimed units).
local function spawn_army(force, center, n)
  local surface = match.surface()
  local list = {}
  for i = 1, n do
    local pos = {x = center.x + ((i - 1) % 4) * 3, y = center.y + math.floor((i - 1) / 4) * 3}
    local e = units.spawn("rts-walker", pos, force, "walker", surface)
    if e then
      local rec = units.get(e.unit_number)
      if rec then rec.order, rec.issuer = "probe", "probe" end
      list[#list + 1] = e
    end
  end
  return list
end

local function health(list)
  local h, alive = 0, 0
  for _, e in ipairs(list) do
    if e.valid then
      h = h + e.health
      alive = alive + 1
    end
  end
  return h, alive
end

local function capital(f)
  local n = storage.nations and storage.nations[f]
  return n and n.capital
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------
local A, B = "rts-ai-1", "rts-ai-2"
local main = {}

main[1] = {at = 20, run = function(s)
  local m = storage.match
  local ok, parts = true, {}
  for _, a in ipairs(m.forces) do
    for _, b in ipairs(m.forces) do
      if a ~= b then
        local st, h, en = diplomacy.state(a, b), diplomacy.hostile(a, b), game.forces[a].is_enemy(game.forces[b])
        if st ~= "peace" or h or en then ok = false end
        parts[#parts + 1] = string.format("%s/%s %s %s %s", a, b, st, tostring(h), tostring(en))
      end
    end
  end
  check("start_peace", ok, "%s", table.concat(parts, "; "))
  local n = game.forces[diplomacy.NEUTRAL]
  local nok = n ~= nil
  for _, a in ipairs(m.forces) do
    if not (diplomacy.hostile(a, diplomacy.NEUTRAL) and diplomacy.hostile(diplomacy.NEUTRAL, a)
            and game.forces[a].is_enemy(n)) then nok = false end
  end
  check("neutral_war", nok, "rts-neutral exists=%s, at war with every nation=%s", tostring(n ~= nil), tostring(nok))
  -- the ceasefire armies
  local W = wars.declare(A, B, {kind = "conquest"})
  wars.ceasefire(W, "probe")
  s.cf_war = W
  local surface = match.surface()
  local c = surface.find_non_colliding_position("rts-walker", {x = 0, y = 0}, 300, 2) or {x = 0, y = 0}
  local c2 = surface.find_non_colliding_position("rts-walker", {x = c.x + 30, y = c.y}, 40, 1) or {x = c.x + 30, y = c.y}
  s.army_a = spawn_army(A, c, 8)
  s.army_b = spawn_army(B, c2, 8)
  s.hp0 = {health(s.army_a), health(s.army_b)}
  -- they march at each other (attack_area engages enemies only), and an explicit attack order is refused
  for _, e in ipairs(s.army_a) do
    e.commandable.set_command({type = defines.command.attack_area, destination = c2, radius = 8,
                               distraction = defines.distraction.by_anything})
  end
  for _, e in ipairs(s.army_b) do
    e.commandable.set_command({type = defines.command.attack_area, destination = c, radius = 8,
                               distraction = defines.distraction.by_anything})
  end
  local loose = units.spawn("rts-walker", {x = c.x - 6, y = c.y}, A, "walker", surface)
  s.loose = loose
  local n_ordered = loose and orders.attack({loose}, s.army_b[1]) or -1
  check("attack_refused", n_ordered == 0, "orders.attack at a ceasefire target ordered %d units", n_ordered)
  util.log("dprobe: ceasefire armies of %d and %d walkers at %s and %s (%.0f tiles), state %s", #s.army_a, #s.army_b,
    util.pos_str(c), util.pos_str(c2), util.distance(c, c2), diplomacy.state(A, B))
end}

main[2] = {at = 140, run = function(s)
  local ha, na = health(s.army_a)
  local hb, nb = health(s.army_b)
  check("ceasefire_no_damage", ha == s.hp0[1] and hb == s.hp0[2] and na == #s.army_a and nb == #s.army_b,
    "after 2 minutes at %s: health %s %.0f -> %.0f (%d alive), %s %.0f -> %.0f (%d alive)", diplomacy.state(A, B),
    A, s.hp0[1], ha, na, B, s.hp0[2], hb, nb)
  -- control: the same armies at war fight (they marched through each other: send them at each other again)
  wars.declare(A, B)
  s.hp1 = {ha + hb}
  local ca, cb = util.centroid(s.army_a), util.centroid(s.army_b)
  for _, e in ipairs(s.army_a) do
    if e.valid and cb then e.commandable.set_command({type = defines.command.attack_area, destination = cb, radius = 12,
      distraction = defines.distraction.by_enemy}) end
  end
  for _, e in ipairs(s.army_b) do
    if e.valid and ca then e.commandable.set_command({type = defines.command.attack_area, destination = ca, radius = 12,
      distraction = defines.distraction.by_enemy}) end
  end
  util.log("dprobe: war resumed, armies %.0f tiles apart, ordered at each other", ca and cb and util.distance(ca, cb) or -1)
end}

main[3] = {at = 170, run = function(s)
  local ha = health(s.army_a)
  local hb = health(s.army_b)
  check("war_control_damage", ha + hb < s.hp1[1], "30 s after the war resumed: health %.0f -> %.0f (state %s)", s.hp1[1],
    ha + hb, diplomacy.state(A, B))
  for _, e in ipairs(s.army_a) do if e.valid then e.destroy() end end
  for _, e in ipairs(s.army_b) do if e.valid then e.destroy() end end
  if s.loose and s.loose.valid then s.loose.destroy() end
  local W = wars.between(A, B)
  if W then wars.end_war(W.id, {kind = "white"}) end
  -- war goal: capture 1 city
  local target = capital("rts-ai-3")
  s.goal_city = target
  s.goal_war = wars.declare("rts-player", "rts-ai-3", {kind = "conquest", cities = {target}})
  util.log("dprobe: war #%s rts-player -> rts-ai-3, goal city %s", tostring(s.goal_war), tostring(target))
end}

main[4] = {at = 180, run = function(s)
  local W = wars.get(s.goal_war)
  check("goal_not_met_yet", W and W.status == "active" and not wars.goals_met(W), "war #%s %s before the capture",
    tostring(s.goal_war), W and W.status or "missing")
  events.emit("rts_city_captured", {city_id = s.goal_city, from = "rts-ai-3", to = "rts-player"})
end}

main[5] = {at = 195, run = function(s)
  local W = wars.get(s.goal_war)
  local t = W and W.treaty
  check("goal_treaty", W and W.status == "ended" and t and t.kind == "cede" and t.city_ids and t.city_ids[1] == s.goal_city
    and diplomacy.state("rts-player", "rts-ai-3") == "peace",
    "war #%s %s, treaty %s, state %s", tostring(s.goal_war), W and W.status or "missing",
    serpent.line(t, {comment = false}), diplomacy.state("rts-player", "rts-ai-3"))
  storage.war_meta.holder[s.goal_city] = nil -- the capture was simulated: the city stays rts-ai-3's for what follows
  -- an AI declares war past its thresholds: rts-ai-2 (aggressive) on rts-ai-3, relation nudged, Age II, more power
  local x, y = "rts-ai-2", "rts-ai-3"
  storage.diplomacy.relations[x][y] = -90
  ages.set_age(x, 2, "dprobe")
  local home = diplomacy.capital_position(x)
  local surface = match.surface()
  for i = 1, 30 do
    local pos = surface.find_non_colliding_position("rts-walker", {x = home.x + 20, y = home.y + 20}, 60, 1)
    if pos then units.spawn("rts-walker", pos, x, "walker", surface) end
  end
  s.decl_from = game.tick
  util.log("dprobe: %s (%s) relation to %s nudged to -90, ratio %.2f, threshold %s", x, diplomacy.doctrine_of(x), y,
    diplomacy.ratio(x, y), serpent.line(diplomacy.thresholds(x), {comment = false}))
end}

main[6] = {at = 270, run = function(s)
  local x, y = "rts-ai-2", "rts-ai-3"
  local W = wars.between(x, y)
  check("ai_declares_war", W ~= nil and W.a == x and W.started >= s.decl_from, "%s", W and string.format(
    "war #%d declared by %s on %s at %.0fs, goals %s", W.id, W.a, W.b, (W.started - storage.match.tick_started) / 60,
    serpent.line(W.goals, {comment = false})) or "no war")
  s.ai_war = W and W.id
  -- a ceasefire offered to the winner (not weary, stronger) is declined
  s.p_decline = diplomacy.propose(y, x, "ceasefire", {})
end}

main[7] = {at = 295, run = function(s)
  local x, y = "rts-ai-2", "rts-ai-3"
  local P1 = diplomacy.get_proposal(s.p_decline)
  check("ceasefire_declined_by_winner", P1 and P1.status == "declined", "proposal #%s %s (%s)", tostring(s.p_decline),
    P1 and P1.status or "missing", P1 and tostring(P1.reason) or "-")
  -- the defender is worn out: 4 cities lost in this war
  local W = wars.get(s.ai_war)
  if W then W.cities_lost[y] = 4 end
  s.weary = W and wars.weariness(W, y) or 0
  s.p_accept = diplomacy.propose(x, y, "ceasefire", {})
  util.log("dprobe: %s weariness nudged to %.0f%% (threshold %d%%)", y, s.weary, diplomacy.thresholds(y).cf_weary)
end}

main[8] = {at = 320, run = function(s)
  local x, y = "rts-ai-2", "rts-ai-3"
  local P2 = diplomacy.get_proposal(s.p_accept)
  check("ceasefire_accepted_weary", P2 and P2.status == "accepted" and P2.reason == "accept-weary"
    and diplomacy.state(x, y) == "ceasefire", "proposal #%s %s (%s) at weariness %.0f%%, answered after %.0f s, state %s",
    tostring(s.p_accept), P2 and P2.status or "missing", P2 and tostring(P2.reason) or "-", s.weary,
    P2 and P2.answered and (P2.answered - P2.tick) / 60 or -1, diplomacy.state(x, y))
  -- Territory: rts-ai-1 holds 61 % from now
  s.terr_from = game.tick
  local real = territory.share
  territory.share = function(f)
    if f == "rts-ai-1" and storage.dprobe and storage.dprobe.terr_from then return 0.61 end
    return real(f)
  end
end}

main[9] = {at = 540, run = function(s)
  local m = storage.match
  check("territory_victory", m.phase == "ended" and m.victory and m.victory.how == "territory"
    and m.winners and m.winners["rts-ai-1"], "phase %s, victory %s", m.phase, serpent.line(m.victory, {comment = false}))
  done()
end}

-- after a load the patched share is gone: patch again while the territory window runs
events.on_load(function()
  if storage.dprobe and storage.dprobe.terr_from then
    local real = territory.share
    territory.share = function(f)
      if f == "rts-ai-1" then return 0.61 end
      return real(f)
    end
  end
end)

match.on_ended(function(m)
  local s = storage.dprobe
  if not s or s.ended_logged then return end
  s.ended_logged = true
  util.log("dprobe: match ended at %.0fs: winner %s, victory %s", age_s(), tostring(m.winner),
    serpent.line(m.victory, {comment = false}))
  if PROBE_MODE == "main" and s.terr_from then
    local dt = (game.tick - s.terr_from) / 60
    check("territory_victory_time", m.victory and m.victory.how == "territory" and dt >= 180 and dt <= 200,
      "territory victory %.0f s after the share reached 61 %%", dt)
  end
end)

---------------------------------------------------------------------------
-- score
---------------------------------------------------------------------------
local score = {}
score[1] = {at = 30, run = function(s)
  local best, bs = nil, -1
  local parts = {}
  for _, f in ipairs(storage.match.forces) do
    local n, p = wars.nation_score(f)
    parts[#parts + 1] = string.format("%s %d %s", f, n, serpent.line(p, {comment = false}))
    if n > bs then best, bs = f, n end
  end
  util.log("dprobe: scores %s", table.concat(parts, "; "))
  -- the best ally with the next nation: shared victory
  local ally
  for _, f in ipairs(storage.match.forces) do
    if f ~= best then
      ally = f
      break
    end
  end
  diplomacy.set_state(best, ally, "alliance", "dprobe")
  s.best, s.ally = best, ally
  -- jump the clock: the time limit has passed
  local m = storage.match
  m.tick_started = game.tick - (m.config.time_limit or 60) * 3600 - 60
  util.log("dprobe: clock set to %.0f min (limit %s), expected winners %s + %s", age_s() / 60, tostring(m.config.time_limit),
    best, ally)
end}
score[2] = {at = 30 + 3600 + 20, run = function(s)
  local m = storage.match
  check("score_victory", m.phase == "ended" and m.victory and m.victory.how == "score" and m.winners
    and m.winners[s.best] and m.winners[s.ally], "phase %s, victory %s, result for %s: %s", m.phase,
    serpent.line(m.victory, {comment = false}), s.ally, tostring(match.result(s.ally)))
  check("score_result_texts", match.result(s.best) == "victory" and match.result(s.ally) == "victory"
    and match.result_text_key(s.best) == "rts.match-victory-score", "result keys %s / %s",
    tostring(match.result_text_key(s.best)), tostring(match.result_text_key(s.ally)))
  done()
end}

events.on_nth_tick(60, function()
  local m = storage.match
  if not (m and m.tick_started) then return end
  local s = S()
  if s.finished then return end
  local list = PROBE_MODE == "score" and score or main
  local step = list[s.step + 1]
  if step and age_s() >= step.at then
    s.step = s.step + 1
    step.run(s)
  end
end)

return P
