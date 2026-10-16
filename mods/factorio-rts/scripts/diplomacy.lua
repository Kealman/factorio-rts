-- Phase 5 M2 diplomacy (docs/PHASE5-M2.md §3 "diplomacy.lua / wars.lua", decisions D6, D7, D9; study
-- docs/research/scale/rails-trade.md §5): the state of every pair of nations and its engine mapping, relations,
-- proposals and their answers, and the AI's diplomatic decisions. scripts/wars.lua owns the wars (goals, war score,
-- weariness, treaties, victory); scripts/diplomacygui.lua the F4 panel and the offers under the HUD alert lines.
--
-- States (symmetric): "war" | "ceasefire" | "peace" | "alliance". Engine mapping (rails-trade.md §5.1):
--   war        set_cease_fire(false) both ways, set_friend(false)
--   ceasefire  set_cease_fire(true) both ways; turns into peace (a white treaty) after ceasefire_minutes
--   peace      set_cease_fire(true) both ways
--   alliance   set_cease_fire(true) and set_friend(true) both ways; share_chart on while a force has an ally
--              (scripts/fog.lua then charts the ally's buildings for the human force)
-- diplomacy.hostile(a, b) is the only force-relation question targeting scripts ask (docs/qa/phase5-diplomacy-notes.md
-- lists every test it replaced). Skirmish: every pair of match forces is at war; hostile asks the engine
-- (LuaForce.is_enemy, memoised per tick and dropped on every cease-fire or friends change), exactly what the
-- targeting scripts asked before M2, so Skirmish behaviour is unchanged. Nation mode: hostile reads the state table;
-- rts-neutral (city-states, D7) is at war with every nation for the whole match (trading with them is M3).
-- A Nation match starts with every pair of nations at balance.nation.diplomacy.start_state ("peace").
--
-- Relations r[a][b] (a's opinion of b) run from -100 to 100 and start at 0. Events (balance.nation.diplomacy.relation):
-- trade +1 per 1,000 cr (cap +10 per minute; diplomacy.note_trade), contract delivered +3 / missed -8
-- (diplomacy.contract_event, signal "rts_contract_event" from market.lua), common enemy +2 per minute, their units on
-- my land (not allies, not at war) -5 per 10 supply per minute, attacked -20 on the first hit of a war then -1 per
-- 1,000 damage, gift +4 per 1,000 cr (halved for every gift of the last 10 minutes), war declared on me -30 (everyone
-- else -5 on the aggressor). Every minute a relation moves 1 point towards the doctrine baseline (economic +10, turtle
-- +5, aggressive -10, a human 0), and an AI nation's rivalry costs friction_doctrine[doctrine] times: 1 towards its
-- nearest neighbour by capital distance, 0.5 towards any other within 1.5 times that distance, 1 more towards a nation
-- it out-powers and can reach. This is the "border friction" of war-ai-performance.md §4.5 that makes an aggressive
-- AI's relation fall past its war threshold.
--
-- Proposals: diplomacy.propose(from, to, kind, terms) -> id, kind = war {goals} | ceasefire | peace {terms} |
-- alliance | contract {item, n_per, deliveries, interval (seconds, market.lua: at least 30), price (per unit), seller,
-- buyer} | gift {cr}. "war" declares at once
-- (wars.declare). An AI answers after 10-20 s with a reason key (rts.diplomacy-reason-<key>); a human answers through
-- the offers under the alert lines or the F4 panel (diplomacy.answer(id, accept)), and an unanswered proposal expires
-- after proposal_ttl. AI decisions (diplomacy.ai_step, every 60 s per AI, staggered) follow the doctrine table of
-- balance.nation.diplomacy.doctrine (rails-trade.md §5.3): declare war when r < war_r and power ratio > war_ratio,
-- offer or accept a ceasefire when ratio < cf_ratio or weariness > cf_weary, offer an alliance when r > ally_r with a
-- common enemy, leave no alliance younger than 10 minutes. Easy AIs never declare war. power(x) = supply of live
-- units + 2 per turret + production value per minute / 500.
--
-- Owns storage.diplomacy = {version, nation, forces = {participant names}, index = {[force] = true}, states, since,
--   relations, why, trade, trade_min, dmg, gifts, truce, allied_at, border, proposals = {[id] = P}, next_id, war_ticks,
--   ai = {[force] = {declined = {[other] = n}}}, stats, minute}; cleared at match teardown. Signals:
--   "rts_diplomacy_changed" {a, b, state, old, why}. Log lines "[rts] diplomacy: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local balance = require("balance")

local diplomacy = {}

diplomacy.NEUTRAL = "rts-neutral"
diplomacy.STATES = {"war", "ceasefire", "peace", "alliance"}
diplomacy.KINDS = {war = true, ceasefire = true, peace = true, alliance = true, contract = true, gift = true}
diplomacy.SLOT = 60          -- scheduler slot in ticks; a minute has 60 slots
diplomacy.AI_SELF_SCHEDULE = true -- false: scripts/ai/nation.lua (M2 wave B) calls diplomacy.ai_step itself
diplomacy.wars = nil         -- scripts/wars.lua sets itself here when it loads (no require loop)

local B = balance.nation.diplomacy
local NEUTRAL = diplomacy.NEUTRAL
local MINUTE = 60 * 60

-- Module lookup at call time (cities, territory, treasury, market, population and the AI load after this module).
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end
diplomacy.loaded = loaded

local function name_of(f)
  if type(f) == "string" then return f end
  return f and f.name or nil
end

local function row(t, a)
  local r = t[a]
  if not r then
    r = {}
    t[a] = r
  end
  return r
end
local function get2(t, a, b)
  local r = t and t[a]
  return r and r[b]
end
local function set2(t, a, b, v) row(t, a)[b] = v end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function fresh()
  return {version = 1, nation = false, forces = {}, index = {}, states = {}, since = {}, relations = {}, why = {},
          trade = {}, trade_min = {}, dmg = {}, gifts = {}, truce = {}, allied_at = {}, border = {}, proposals = {},
          next_id = 1, war_ticks = {}, ai = {}, minute = 0,
          stats = {declared = 0, ceasefires = 0, peaces = 0, alliances = 0, proposals = 0, accepted = 0, declined = 0,
                   expired = 0, refused_attacks = 0}}
end

local function dstate()
  local D = storage.diplomacy
  if not D then
    D = fresh()
    storage.diplomacy = D
  end
  return D
end

function diplomacy.init()
  dstate()
end

--- True while a Nation match keeps diplomatic states (from its start until teardown).
function diplomacy.nation()
  local D = storage.diplomacy
  return D ~= nil and D.nation == true
end

--- The nations of the match (participants, rts-player first). Empty outside a Nation match.
function diplomacy.nations()
  local D = storage.diplomacy
  return (D and D.nation and D.forces) or {}
end

--- True when `f` is a nation of the current Nation match.
function diplomacy.is_nation(f)
  local D = storage.diplomacy
  return D ~= nil and D.nation == true and D.index[name_of(f)] == true
end

local function alive(f)
  local m = storage.match
  return not (m and m.out and m.out[f])
end

--- Localised name of a nation or of the city-states.
function diplomacy.label(f)
  f = name_of(f)
  if f == NEUTRAL then return {"rts.diplomacy-city-states"} end
  return match.label(f)
end

--- Capital position of a nation (its capital City Center, else its spawn).
function diplomacy.capital_position(f)
  local cities = loaded("scripts.cities")
  local n = storage.nations and storage.nations[f]
  local c = cities and n and n.capital and cities.get(n.capital)
  if c and c.position then return {x = c.position.x, y = c.position.y} end
  local h = match.home(f)
  return {x = h.x, y = h.y}
end

---------------------------------------------------------------------------
-- The question: hostile(a, b)
---------------------------------------------------------------------------
-- Engine view (Skirmish, and pairs the Nation table does not know): LuaForce.is_enemy, memoised per tick and match
-- phase, dropped whenever a cease-fire or friends list changes (on_force_cease_fire_changed / on_force_friends_changed
-- are raised synchronously for script changes too, probe 2026-10-16). Module-local: never game state.
local memo, memo_tick, memo_phase = {}, -1, nil
local function engine_hostile(a, b)
  local tick = game.tick
  local m = storage.match
  local phase = m and m.phase
  if tick ~= memo_tick or phase ~= memo_phase then memo, memo_tick, memo_phase = {}, tick, phase end
  local r = memo[a]
  if not r then
    r = {}
    memo[a] = r
  end
  local v = r[b]
  if v == nil then
    local fa, fb = game.forces[a], game.forces[b]
    v = fa ~= nil and fb ~= nil and fa.is_enemy(fb) == true
    r[b] = v
  end
  return v
end

function diplomacy.invalidate() memo_tick = -1 end

--- The only force-relation question a targeting script may ask: may units of `a` attack `b`? Forces or names.
function diplomacy.hostile(a, b)
  a, b = name_of(a), name_of(b)
  if a == nil or b == nil or a == b then return false end
  local D = storage.diplomacy
  if D and D.nation then
    local s = D.states[a]
    s = s and s[b]
    if s then
      local m = storage.match
      if m and m.phase == "ended" then return false end -- the calm after the end (match.lua ceases fire everywhere)
      return s == "war"
    end
  end
  return engine_hostile(a, b)
end

--- "war" | "ceasefire" | "peace" | "alliance" between two forces. Skirmish: always "war" (a force with itself:
--- "alliance").
function diplomacy.state(a, b)
  a, b = name_of(a), name_of(b)
  if a == b then return "alliance" end
  local D = storage.diplomacy
  if D and D.nation then
    local s = get2(D.states, a, b)
    if s then return s end
    return engine_hostile(a, b) and "war" or "peace"
  end
  return "war"
end

--- Tick the pair's current state began (nil outside Nation mode).
function diplomacy.since(a, b) return get2(dstate().since, name_of(a), name_of(b)) end

--- True when a and b are allied.
function diplomacy.allied(a, b) return diplomacy.state(a, b) == "alliance" and name_of(a) ~= name_of(b) end

--- The allies of a nation (names).
function diplomacy.allies(f)
  f = name_of(f)
  local out = {}
  for _, o in ipairs(diplomacy.nations()) do
    if o ~= f and get2(storage.diplomacy.states, f, o) == "alliance" then out[#out + 1] = o end
  end
  return out
end

--- True when units of `attacker` must not attack `target_force` although it is another nation (or the city-states):
--- orders.lua refuses such an attack with a message. Vanilla forces (trees, rocks) are never refused.
function diplomacy.refuses_attack(attacker, target_force)
  attacker, target_force = name_of(attacker), name_of(target_force)
  if not (attacker and target_force) or attacker == target_force then return false end
  if not diplomacy.nation() then return false end
  if not (diplomacy.is_nation(target_force) or target_force == NEUTRAL) then return false end
  return not diplomacy.hostile(attacker, target_force)
end

--- Count a refused attack (orders.lua) for the stats line.
function diplomacy.note_refused(attacker, target_force)
  local D = dstate()
  D.stats.refused_attacks = D.stats.refused_attacks + 1
  util.log("diplomacy: attack by %s on %s refused (%s)", tostring(attacker), tostring(target_force),
    diplomacy.state(attacker, target_force))
end

---------------------------------------------------------------------------
-- Engine mapping and state changes
---------------------------------------------------------------------------
local function has_ally(f)
  local D = storage.diplomacy
  local r = D and D.states[f]
  if not r then return false end
  for _, s in pairs(r) do
    if s == "alliance" then return true end
  end
  return false
end
diplomacy.has_ally = has_ally

local function apply_engine(a, b, state)
  local fa, fb = game.forces[a], game.forces[b]
  if not (fa and fb) then return end
  local cf = state ~= "war"
  local fr = state == "alliance"
  fa.set_cease_fire(fb, cf)
  fb.set_cease_fire(fa, cf)
  fa.set_friend(fb, fr)
  fb.set_friend(fa, fr)
  fa.share_chart = has_ally(a)
  fb.share_chart = has_ally(b)
  memo_tick = -1
end

local ALERT_KIND = {war = "diplomacy-war", ceasefire = "diplomacy-ceasefire", peace = "diplomacy-peace",
                    alliance = "diplomacy-alliance"}

-- An alert (storage.alerts, HUD lines, F3) for a human force; positions are the other nation's capital.
-- Only forces people look at get them (rts-player, any force with players), like hud.lua's base-attacked alert.
local function alert(to, kind, text, params, about)
  local supply = loaded("scripts.supply")
  local force = game.forces[to]
  if not (supply and force) or (to ~= util.PLAYER_FORCE and #force.players == 0) then return end
  supply.alert(to, kind, text, params, about and diplomacy.capital_position(about) or nil)
end
diplomacy.alert = alert

--- Set the state of a pair (both directions) and apply the engine mapping. opts.silent: no alerts (wars.lua writes
--- its own). Returns true when the state changed.
function diplomacy.set_state(a, b, state, why, opts)
  a, b = name_of(a), name_of(b)
  local D = dstate()
  if not D.nation or a == b or not (D.index[a] or a == NEUTRAL) or not (D.index[b] or b == NEUTRAL) then return false end
  if (a == NEUTRAL or b == NEUTRAL) and state ~= "war" then return false end -- city-states stay at war in M2
  local old = get2(D.states, a, b) or "war"
  if old == state then return false end
  set2(D.states, a, b, state)
  set2(D.states, b, a, state)
  set2(D.since, a, b, game.tick)
  set2(D.since, b, a, game.tick)
  if state ~= "war" then -- the next war starts with a "first hit" again
    if D.dmg[a] then D.dmg[a][b] = nil end
    if D.dmg[b] then D.dmg[b][a] = nil end
  end
  if state == "alliance" then
    set2(D.allied_at, a, b, game.tick)
    set2(D.allied_at, b, a, game.tick)
    D.stats.alliances = D.stats.alliances + 1
  elseif state == "ceasefire" then
    D.stats.ceasefires = D.stats.ceasefires + 1
  elseif state == "peace" and old ~= "alliance" then
    D.stats.peaces = D.stats.peaces + 1
  end
  apply_engine(a, b, state)
  util.log("diplomacy: %s / %s: %s -> %s (%s) at %.0fs", a, b, old, state, tostring(why), match.elapsed_seconds())
  if not (opts and opts.silent) then
    local kind = ALERT_KIND[state] or "diplomacy-peace"
    alert(a, kind, "rts.diplomacy-alert-" .. state, {diplomacy.label(b)}, b)
    alert(b, kind, "rts.diplomacy-alert-" .. state, {diplomacy.label(a)}, a)
  end
  events.emit("rts_diplomacy_changed", {a = a, b = b, state = state, old = old, why = why})
  return true
end

---------------------------------------------------------------------------
-- Relations
---------------------------------------------------------------------------
--- a's opinion of b, -100..100 (0 outside Nation mode).
function diplomacy.relation(a, b)
  local D = storage.diplomacy
  return (D and get2(D.relations, name_of(a), name_of(b))) or 0
end

--- Change a's opinion of b by delta (clamped to -100..100); `why` is a reason key (rts.diplomacy-why-<key>).
--- Returns the new value, or nil outside a Nation match / for unknown forces.
function diplomacy.adjust(a, b, delta, why)
  a, b = name_of(a), name_of(b)
  local D = storage.diplomacy
  if not (D and D.nation and D.index[a] and D.index[b]) or a == b or delta == 0 then return nil end
  local old = get2(D.relations, a, b) or 0
  local r = clamp(old + delta, -100, 100)
  set2(D.relations, a, b, r)
  set2(D.why, a, b, {key = why, delta = delta, tick = game.tick})
  if math.abs(delta) >= 5 then
    util.log("diplomacy: relation %s -> %s %+.1f (%s) = %.1f", a, b, delta, tostring(why), r)
  end
  return r
end

--- Both directions at once.
function diplomacy.adjust_both(a, b, delta, why)
  diplomacy.adjust(a, b, delta, why)
  diplomacy.adjust(b, a, delta, why)
end

--- Trade between two nations worth `cr` crowns (scripts/market.lua contracts): +1 per 1,000 cr both ways, at most
--- +10 per minute; the panel shows the volume.
function diplomacy.note_trade(a, b, cr)
  a, b = name_of(a), name_of(b)
  local D = storage.diplomacy
  if not (D and D.nation and D.index[a] and D.index[b]) or a == b or not cr or cr <= 0 then return end
  set2(D.trade, a, b, (get2(D.trade, a, b) or 0) + cr)
  set2(D.trade, b, a, (get2(D.trade, b, a) or 0) + cr)
  local R = B.relation
  for _, p in ipairs({{a, b}, {b, a}}) do
    local used = get2(D.trade_min, p[1], p[2]) or 0
    local gain = math.min(R.trade_cap_per_min - used, cr / 1000 * R.trade_per_1000)
    if gain > 0 then
      set2(D.trade_min, p[1], p[2], used + gain)
      diplomacy.adjust(p[1], p[2], gain, "trade")
    end
  end
end

--- Trade volume between two nations so far (crowns).
function diplomacy.trade_volume(a, b) return get2(dstate().trade, name_of(a), name_of(b)) or 0 end

--- A contract delivery between seller and buyer (market.lua): delivered +3 both ways, missed -8 (the wronged side's
--- opinion of the side at fault: `fault` = "seller" (default) | "buyer"). `cr` adds to the trade volume when delivered.
function diplomacy.contract_event(seller, buyer, delivered, cr, fault)
  local R = B.relation
  if delivered then
    diplomacy.adjust_both(seller, buyer, R.contract_delivered, "contract-delivered")
    if cr and cr > 0 then diplomacy.note_trade(seller, buyer, cr) end
  elseif fault == "buyer" then
    diplomacy.adjust(seller, buyer, R.contract_missed, "contract-missed")
  else
    diplomacy.adjust(buyer, seller, R.contract_missed, "contract-missed")
  end
end

-- scripts/market.lua (m2-treasury) reports contracts through the signal "rts_contract_event" {kind = "created" |
-- "delivered" | "late" | "missed" | "completed" | "cancelled", id, seller, buyer, item, n, delivery, deliveries, price,
-- value, fault}: a delivery counts +3 and its value as trade, a miss (2 minutes after a late delivery) -8.
events.on_signal("rts_contract_event", function(ev)
  if not ev then return end
  if ev.kind == "delivered" then
    diplomacy.contract_event(ev.seller, ev.buyer, true, ev.value)
  elseif ev.kind == "missed" then
    diplomacy.contract_event(ev.seller, ev.buyer, false, nil, ev.fault)
  end
end)

---------------------------------------------------------------------------
-- Doctrines, humans, power
---------------------------------------------------------------------------
local function commander_of(f)
  local ai = loaded("scripts.ai.init")
  return ai and ai.get and ai.get(f) or nil
end

--- True when a human plays this force (it has connected players): proposals to it wait for an answer.
function diplomacy.is_human(f)
  local force = game.forces[name_of(f)]
  return force ~= nil and #force.connected_players > 0
end

--- True when an AI commander decides for this force (and no human plays it).
function diplomacy.is_ai(f)
  return not diplomacy.is_human(f) and commander_of(name_of(f)) ~= nil
end

--- "economic" | "aggressive" | "turtle" for an AI force, "human" otherwise.
function diplomacy.doctrine_of(f)
  f = name_of(f)
  if diplomacy.is_human(f) then return "human" end
  local C = commander_of(f)
  return C and C.doctrine or "human"
end

function diplomacy.baseline(f)
  return B.baseline[diplomacy.doctrine_of(f)] or 0
end

local function table_of(f)
  return B.doctrine[diplomacy.doctrine_of(f)] or B.doctrine.economic
end
diplomacy.thresholds = table_of

-- Production value per minute of a force: the last minute's output of a few goods (item production statistics on the
-- arena) at their value (market prices when scripts/market.lua exists, else balance.nation.diplomacy.power.values).
local function production_value(f)
  local force, surface = game.forces[f], match.surface()
  if not (force and surface) then return 0 end
  local ok, stats = pcall(force.get_item_production_statistics, surface)
  if not ok or not stats then return 0 end
  local market = loaded("scripts.market")
  local v = 0
  for item, value in pairs(B.power.values) do
    local okc, n = pcall(stats.get_flow_count, {name = item, category = "input",
      precision_index = defines.flow_precision_index.one_minute, count = true})
    if okc and n then
      local price = market and market.price and market.price(item) or value
      v = v + n * (price or value)
    end
  end
  return v
end

--- Military and economic power of every nation: {[force] = n}, cached for power.cache_ticks in storage.diplomacy.power
--- (in storage, not module-local: AI decisions read it, and every client must see the same cache).
function diplomacy.powers()
  local D = dstate()
  local cache = D.power
  if cache and game.tick - cache.tick < B.power.cache_ticks then return cache.by end
  local by = {}
  local nations = diplomacy.nations()
  for _, f in ipairs(nations) do by[f] = 0 end
  local skip = B.power.skip_kinds
  for _, rec in pairs(storage.units or {}) do
    local f = rec.force
    if by[f] and not skip[rec.kind] and rec.entity.valid then
      local b = balance.units[rec.entity.name]
      by[f] = by[f] + ((b and b.supply) or 1)
    end
  end
  local turrets = B.power.turret_kinds
  for _, rec in pairs(storage.buildings or {}) do
    local f = rec.force
    if by[f] and turrets[rec.kind] and rec.entity.valid then by[f] = by[f] + B.power.turret end
  end
  for _, f in ipairs(nations) do by[f] = by[f] + production_value(f) / B.power.production_divisor end
  D.power = {tick = game.tick, by = by}
  return by
end

--- power(a) / power(b) (b's power at least 1).
function diplomacy.ratio(a, b)
  local p = diplomacy.powers()
  return (p[name_of(a)] or 0) / math.max(1, p[name_of(b)] or 0)
end

--- True when a and b are both at war with some third nation (not with each other).
function diplomacy.common_enemy(a, b)
  local D = storage.diplomacy
  if not (D and D.nation) then return false end
  for _, z in ipairs(D.forces) do
    if z ~= a and z ~= b and alive(z) and get2(D.states, a, z) == "war" and get2(D.states, b, z) == "war" then
      return true
    end
  end
  return false
end

--- True when the nation is at war with another nation (city-states do not count).
function diplomacy.at_war(f)
  local D = storage.diplomacy
  if not (D and D.nation) then return false end
  for _, o in ipairs(D.forces) do
    if o ~= f and alive(o) and get2(D.states, f, o) == "war" then return true end
  end
  return false
end

--- Ticks a nation spent at war with another nation in this match (counted per minute).
function diplomacy.war_ticks(f)
  local D = storage.diplomacy
  return D and D.war_ticks[name_of(f)] or 0
end

---------------------------------------------------------------------------
-- Proposals
---------------------------------------------------------------------------
-- Deterministic answer delay of 10-20 s (no RNG state needed): a hash of the proposal id and tick.
local function answer_delay(id)
  local lo, hi = B.answer_ticks[1], B.answer_ticks[2]
  return lo + (id * 7919 + game.tick * 31) % (hi - lo + 1)
end

local function pending_between(from, to, kind)
  for _, P in pairs(dstate().proposals) do
    if P.status == "pending" and P.from == from and P.to == to and (kind == nil or P.kind == kind) then return P end
  end
  return nil
end
diplomacy.pending_between = pending_between

--- Proposals addressed to a force that wait for an answer, oldest first.
function diplomacy.pending_for(to)
  local out = {}
  for _, P in pairs(dstate().proposals) do
    if P.status == "pending" and P.to == to then out[#out + 1] = P end
  end
  table.sort(out, function(x, y) return x.id < y.id end)
  return out
end

function diplomacy.get_proposal(id) return dstate().proposals[id] end

-- Why a proposal cannot be made at all (nil = it can).
local function invalid(from, to, kind, terms)
  local D = storage.diplomacy
  if not (D and D.nation) then return "not-nation" end
  if not diplomacy.KINDS[kind] then return "unknown-kind" end
  if from == to or not D.index[from] or not D.index[to] then return "unknown-nation" end
  if not (alive(from) and alive(to)) then return "eliminated" end
  local st = get2(D.states, from, to)
  if kind == "war" and st == "war" then return "already-at-war" end
  if kind == "war" and st == "alliance" then return "allied" end
  if kind == "ceasefire" and st ~= "war" then return "not-at-war" end
  if kind == "peace" and st ~= "war" and st ~= "ceasefire" then return "not-at-war" end
  if kind == "alliance" and st == "alliance" then return "already-allied" end
  if kind == "alliance" and st ~= "peace" then return "not-at-peace" end
  if kind == "gift" and not (terms and (terms.cr or 0) > 0) then return "no-amount" end
  if kind ~= "war" and pending_between(from, to, kind) then return "pending" end
  return nil
end
diplomacy.invalid = invalid

local apply_accepted -- below

--- Propose `kind` from one nation to another. Returns the proposal id, or nil and a reason key.
function diplomacy.propose(from, to, kind, terms)
  from, to = name_of(from), name_of(to)
  terms = terms or {}
  local why = invalid(from, to, kind, terms)
  if why then
    util.log("diplomacy: proposal %s %s -> %s refused (%s)", tostring(kind), tostring(from), tostring(to), why)
    return nil, why
  end
  local D = dstate()
  local id = D.next_id
  D.next_id = id + 1
  local P = {id = id, from = from, to = to, kind = kind, terms = terms, tick = game.tick, status = "pending"}
  D.proposals[id] = P
  D.stats.proposals = D.stats.proposals + 1
  if kind == "war" then -- a declaration needs no answer
    local wars = diplomacy.wars
    local war_id, reason
    if wars then war_id, reason = wars.declare(from, to, terms.goals or terms) else reason = "no-wars" end
    P.status, P.reason, P.answered, P.war_id = war_id and "accepted" or "declined", war_id and "declared" or reason,
      game.tick, war_id
    return id
  end
  if diplomacy.is_human(to) then
    P.expires = game.tick + B.proposal_ttl
    alert(to, "diplomacy-proposal", "rts.diplomacy-alert-proposal-" .. kind, {diplomacy.label(from)}, from)
  else
    P.answer_at = game.tick + answer_delay(id)
  end
  util.log("diplomacy: proposal #%d %s %s -> %s %s%s", id, kind, from, to, serpent.line(terms, {comment = false}),
    P.answer_at and string.format(" (answer in %.0f s)", (P.answer_at - game.tick) / 60) or " (waits for a player)")
  return id
end

local function finish_proposal(P, accept, reason)
  local D = dstate()
  P.status = accept and "accepted" or "declined"
  P.reason = reason
  P.answered = game.tick
  if accept then D.stats.accepted = D.stats.accepted + 1 else D.stats.declined = D.stats.declined + 1 end
  if not accept and P.kind ~= "war" then
    local a = row(D.ai, P.from)
    a.declined = a.declined or {}
    a.declined[P.to] = (a.declined[P.to] or 0) + 1
  end
  util.log("diplomacy: proposal #%d %s %s -> %s %s (%s)", P.id, P.kind, P.from, P.to, P.status, tostring(reason))
  -- the proposer learns the answer (a human through an alert)
  local key = "rts.diplomacy-alert-answer-" .. (accept and "accepted" or "declined")
  alert(P.from, accept and "diplomacy-answer" or "diplomacy-declined", key,
    {diplomacy.label(P.to), {"rts.diplomacy-kind-" .. P.kind}, {"rts.diplomacy-reason-" .. tostring(reason),
     P.reason_param or ""}}, P.to)
end

--- Answer a pending proposal (players through the GUI; the AI through its scheduler). Returns true when it was
--- pending and is now answered. `reason` defaults to "player-accept" / "player-decline".
function diplomacy.answer(id, accept, reason)
  local P = dstate().proposals[id]
  if not (P and P.status == "pending") then return false end
  local why = invalid(P.from, P.to, P.kind, P.terms)
  if why and why ~= "pending" then
    P.status, P.reason, P.answered = "void", why, game.tick
    util.log("diplomacy: proposal #%d %s void (%s)", P.id, P.kind, why)
    return false
  end
  if accept then
    local ok, fail = apply_accepted(P)
    if not ok then
      finish_proposal(P, false, fail or "failed")
      return true
    end
  end
  finish_proposal(P, accept, reason or (accept and "player-accept" or "player-decline"))
  return true
end

---------------------------------------------------------------------------
-- Accepted proposals
---------------------------------------------------------------------------
local function treasury_transfer(from, to, cr, why)
  local treasury = loaded("scripts.treasury")
  if not (treasury and treasury.charge and treasury.add) then return false, "no-treasury" end
  if not treasury.charge(from, cr, why) then return false, "no-money" end
  treasury.add(to, cr, why)
  return true
end
diplomacy.treasury_transfer = treasury_transfer

apply_accepted = function(P)
  local wars = diplomacy.wars
  local D = dstate()
  local a, b, t = P.from, P.to, P.terms or {}
  if P.kind == "ceasefire" then
    local W = wars and wars.between(a, b)
    if W then return wars.ceasefire(W.id, a) end
    return diplomacy.set_state(a, b, "ceasefire", "proposal #" .. P.id)
  elseif P.kind == "peace" then
    local W = wars and wars.between(a, b)
    local treaty = t.treaty or {kind = t.kind or "white", city_ids = t.city_ids, cr_per_min = t.cr_per_min,
                                minutes = t.minutes, payer = t.payer, payee = t.payee, to = t.to}
    if W then return wars.end_war(W.id, treaty) end
    diplomacy.set_state(a, b, "peace", "proposal #" .. P.id)
    return true
  elseif P.kind == "alliance" then
    return diplomacy.set_state(a, b, "alliance", "proposal #" .. P.id)
  elseif P.kind == "gift" then
    local cr = t.cr or 0
    local ok, why = treasury_transfer(a, b, cr, "gift")
    if not ok then return false, why end
    local g = row(D.gifts, a)
    local recent = 0
    local list = g[b] or {}
    local keep = {}
    for _, tick in ipairs(list) do
      if game.tick - tick < 10 * MINUTE then
        recent = recent + 1
        keep[#keep + 1] = tick
      end
    end
    keep[#keep + 1] = game.tick
    g[b] = keep
    diplomacy.adjust(b, a, B.relation.gift_per_1000 * cr / 1000 * (0.5 ^ recent), "gift")
    return true
  elseif P.kind == "contract" then
    local market = loaded("scripts.market")
    if not (market and market.contract) then return false, "no-market" end
    local seller, buyer = t.seller or a, t.buyer or b
    local cid = market.contract(seller, buyer, t.item, t.n_per, t.deliveries, t.interval, t.price)
    if not cid then return false, "market-refused" end
    P.contract_id = cid
    return true
  end
  return false, "unknown-kind"
end

---------------------------------------------------------------------------
-- AI: answers and decisions
---------------------------------------------------------------------------
-- Supply of b's units on a's land last minute (border incidents), for "you have N units inside our border".
local function border_supply(a, b) return get2(dstate().border, a, b) or 0 end
diplomacy.border_supply = border_supply

--- The AI's answer to a proposal addressed to it: accept (bool), reason key, reason parameter.
function diplomacy.ai_answer(P)
  local x, y = P.to, P.from
  local T = table_of(x)
  local wars = diplomacy.wars
  local st = diplomacy.state(x, y)
  local r = diplomacy.relation(x, y)
  local ratio = diplomacy.ratio(x, y)
  local t = P.terms or {}
  if P.kind == "ceasefire" or P.kind == "peace" then
    local W = wars and wars.between(x, y)
    local weary = W and wars.weariness(W, x) or 0
    local minutes = W and wars.minutes(W) or 0
    local kind = P.kind == "peace" and (t.kind or (t.treaty and t.treaty.kind) or "white") or "white"
    if kind ~= "white" then
      local payer = t.payer or (t.treaty and t.treaty.payer)
      local to = t.to or (t.treaty and t.treaty.to)
      local gains = (kind == "tribute" and payer == y) or (kind == "cede" and to == x)
      if gains then return true, "accept-terms" end
      if weary > B.terms_weary_factor * T.cf_weary then return true, "accept-weary" end
      return false, "decline-terms"
    end
    if weary > T.cf_weary then return true, "accept-weary" end
    if ratio < T.cf_ratio then return true, "accept-weak" end
    if W and minutes >= B.long_war_minutes and wars.net_score(W, x) < B.long_war_score then return true, "accept-long-war" end
    if P.kind == "peace" and st == "ceasefire" and r > B.peace_from_ceasefire_r then return true, "accept-ceasefire-holds" end
    if W and wars.goals_met(W) and W.a == x then return true, "accept-goals" end
    return false, "decline-winning"
  elseif P.kind == "alliance" then
    if st ~= "peace" then return false, "decline-state" end
    local n = border_supply(x, y)
    if n >= B.border_decline_supply then return false, "decline-border", n end
    if r < T.ally_r - B.ally_accept_slack then return false, "decline-relation" end
    if not diplomacy.common_enemy(x, y) then return false, "decline-no-common-enemy" end
    return true, "accept-friends"
  elseif P.kind == "contract" then
    if not loaded("scripts.market") then return false, "decline-no-market" end
    local n = border_supply(x, y)
    if n >= B.border_decline_supply then return false, "decline-border", n end
    if st == "war" then return false, "decline-state" end
    if r < B.contract_min_r then return false, "decline-relation" end
    return true, "accept-trade"
  elseif P.kind == "gift" then
    if not loaded("scripts.treasury") then return false, "decline-no-treasury" end
    return true, "accept-gift"
  end
  return false, "decline-state"
end

-- The goals of an AI's war on y: capture y's city nearest to x's capital (kind "conquest", one city), or y's capital.
local function ai_goals(x, y)
  local cities = loaded("scripts.cities")
  local home = diplomacy.capital_position(x)
  local best, bd
  for _, c in ipairs(cities and cities.for_force(y) or {}) do
    if c.position then
      local d = util.distance(home, c.position)
      if not bd or d < bd then best, bd = c, d end
    end
  end
  if best then return {kind = "conquest", cities = {best.id}} end
  return {kind = "capital"}
end
diplomacy.ai_goals = ai_goals

-- Distance from x's capital to y's nearest city (or capital).
local function reach_distance(x, y)
  local cities = loaded("scripts.cities")
  local home = diplomacy.capital_position(x)
  local bd = util.distance(home, diplomacy.capital_position(y))
  for _, c in ipairs(cities and cities.for_force(y) or {}) do
    if c.position then bd = math.min(bd, util.distance(home, c.position)) end
  end
  return bd
end

-- Can x's army reach y in its age? Age I armies attack nothing beyond ai/army.lua NATION_AGE1_REACH.
local function can_reach(x, y)
  local ages = loaded("scripts.ages")
  if not ages or (ages.of and ages.of(x) >= 2) then return true end
  local army = loaded("scripts.ai.army")
  local reach = army and army.NATION_AGE1_REACH or 500
  return reach_distance(x, y) <= reach
end

local function offensive_war(x)
  local wars = diplomacy.wars
  if not wars then return false end
  for _, id in ipairs(wars.active(x)) do
    local W = wars.get(id)
    if W and W.a == x then return true end
  end
  return false
end

--- One AI decision pass for force x (every 60 s, or from scripts/ai/nation.lua). Returns the actions taken.
function diplomacy.ai_step(x)
  local D = storage.diplomacy
  if not (D and D.nation and D.index[x]) or not alive(x) or not diplomacy.is_ai(x) then return 0 end
  local wars = diplomacy.wars
  local C = commander_of(x)
  local T = table_of(x)
  local easy = C and C.difficulty == "easy"
  local tick = game.tick
  local actions = 0
  for _, y in ipairs(D.forces) do
    if y ~= x and alive(y) then
      local st = get2(D.states, x, y)
      local r = diplomacy.relation(x, y)
      local ratio = diplomacy.ratio(x, y)
      if st == "war" then
        local W = wars and wars.between(x, y)
        local weary = W and wars.weariness(W, x) or 0
        local minutes = W and wars.minutes(W) or 0
        local last = D.ai[x] and D.ai[x].offered and D.ai[x].offered[y]
        if minutes >= B.min_war_minutes and (ratio < T.cf_ratio or weary > T.cf_weary)
           and not pending_between(x, y) and not (last and tick - last < B.offer_cooldown_minutes * MINUTE) then
          local a = row(D.ai, x)
          a.offered = a.offered or {}
          a.offered[y] = tick
          local declined = D.ai[x] and D.ai[x].declined and D.ai[x].declined[y] or 0
          if declined >= 2 and weary > B.terms_weary_factor * T.cf_weary and W then
            local Tr = B.tribute_offer
            diplomacy.propose(x, y, "peace", {kind = "tribute", payer = x, payee = y, cr_per_min = Tr.cr_per_min,
                                              minutes = Tr.minutes})
          else
            diplomacy.propose(x, y, "ceasefire", {})
          end
          actions = actions + 1
          util.log("diplomacy: ai %s wants out of the war with %s: ratio %.2f (< %.2f?), weariness %.0f%% (> %d%%?)",
            x, y, ratio, T.cf_ratio, weary, T.cf_weary)
        end
      elseif st == "peace" then
        local truce = get2(D.truce, x, y)
        local last = D.ai[x] and D.ai[x].offered and D.ai[x].offered[y]
        if r > T.ally_r and diplomacy.common_enemy(x, y) and not pending_between(x, y, "alliance")
           and border_supply(x, y) < B.border_decline_supply
           and not (last and tick - last < B.offer_cooldown_minutes * MINUTE) then
          local a = row(D.ai, x)
          a.offered = a.offered or {}
          a.offered[y] = tick
          diplomacy.propose(x, y, "alliance", {})
          actions = actions + 1
        elseif not easy and r < T.war_r and ratio > T.war_ratio and not (truce and tick < truce)
               and not offensive_war(x) and can_reach(x, y) and wars then
          local goals = ai_goals(x, y)
          util.log("diplomacy: ai %s (%s) declares war on %s: relation %.1f < %d, power ratio %.2f > %.2f",
            x, diplomacy.doctrine_of(x), y, r, T.war_r, ratio, T.war_ratio)
          diplomacy.propose(x, y, "war", {goals = goals})
          actions = actions + 1
        end
      elseif st == "alliance" then
        local at = get2(D.allied_at, x, y) or 0
        if r < B.break_alliance_r and tick - at >= B.alliance_lock_minutes * MINUTE then
          diplomacy.set_state(x, y, "peace", "alliance-left")
          diplomacy.adjust(y, x, B.relation.alliance_left, "alliance-left")
          actions = actions + 1
        end
      end
    end
  end
  return actions
end

-- Answer due AI proposals; expire old human ones.
local function answer_due(tick)
  local D = storage.diplomacy
  for id, P in pairs(D.proposals) do
    if P.status == "pending" then
      if P.answer_at and tick >= P.answer_at then
        if diplomacy.is_human(P.to) then
          P.answer_at, P.expires = nil, tick + B.proposal_ttl -- a player took over the force: wait for them
        else
          local accept, reason, param = diplomacy.ai_answer(P)
          P.reason_param = param
          diplomacy.answer(id, accept, reason)
        end
      elseif P.expires and tick >= P.expires then
        P.status, P.reason, P.answered = "expired", "expired", tick
        D.stats.expired = D.stats.expired + 1
        util.log("diplomacy: proposal #%d %s %s -> %s expired", P.id, P.kind, P.from, P.to)
        alert(P.from, "diplomacy-declined", "rts.diplomacy-alert-answer-declined",
          {diplomacy.label(P.to), {"rts.diplomacy-kind-" .. P.kind}, {"rts.diplomacy-reason-expired", ""}}, P.to)
      end
    elseif P.answered and tick - P.answered > 10 * MINUTE then
      D.proposals[id] = nil -- answered long ago: forget
    end
  end
end

---------------------------------------------------------------------------
-- Per-minute relation changes
---------------------------------------------------------------------------
-- Nearest other nation of each nation by capital distance: {[a] = {nearest = b, d = n}, dist = {[a] = {[b] = d}}}.
local function distances(nations)
  local pos, dist, near = {}, {}, {}
  for _, f in ipairs(nations) do pos[f] = diplomacy.capital_position(f) end
  for _, a in ipairs(nations) do
    dist[a] = {}
    for _, b in ipairs(nations) do
      if a ~= b then
        local d = util.distance(pos[a], pos[b])
        dist[a][b] = d
        if alive(b) and (not near[a] or d < near[a].d) then near[a] = {nearest = b, d = d} end
      end
    end
  end
  return dist, near
end

-- Friction per minute a feels towards b (rivalry with the nearest neighbours; balance.nation.diplomacy.relation).
local function friction(a, b, dist, near)
  local R = B.relation
  local factor = R.friction_doctrine[diplomacy.doctrine_of(a)] or 0
  if factor == 0 or not near[a] then return 0 end
  local f = 0
  if near[a].nearest == b then
    f = R.friction.nearest
  elseif dist[a][b] <= near[a].d * R.friction.near_factor then
    f = R.friction.near
  end
  -- opportunism: a nation it out-powers and can reach
  if R.friction.weaker > 0 and diplomacy.ratio(a, b) > table_of(a).war_ratio and can_reach(a, b) then
    f = f + R.friction.weaker
  end
  return factor * f
end
diplomacy.friction = function(a, b)
  local dist, near = distances(diplomacy.nations())
  return friction(a, b, dist, near)
end

local function minute_step()
  local D = storage.diplomacy
  D.minute = D.minute + 1
  local R = B.relation
  local nations = D.forces
  local dist, near = distances(nations)
  for _, f in ipairs(nations) do
    if alive(f) and diplomacy.at_war(f) then D.war_ticks[f] = (D.war_ticks[f] or 0) + MINUTE end
  end
  local parts = {}
  for _, a in ipairs(nations) do
    for _, b in ipairs(nations) do
      if a ~= b and alive(a) and alive(b) then
        local st = get2(D.states, a, b)
        local delta = 0
        -- attacked: -1 per 1,000 damage since the last minute
        local hit = D.dmg[a] and D.dmg[a][b]
        if hit and hit.acc >= 1000 then
          local k = math.floor(hit.acc / 1000)
          hit.acc = hit.acc - k * 1000
          delta = delta + k * R.attacked_per_1000
        end
        if st ~= "war" and diplomacy.common_enemy(a, b) then delta = delta + R.common_enemy_per_min end
        if st == "peace" or st == "ceasefire" then delta = delta - friction(a, b, dist, near) end
        if delta ~= 0 then diplomacy.adjust(a, b, delta, "minute") end
        -- decay towards the baseline
        local base = diplomacy.baseline(a)
        local r = diplomacy.relation(a, b)
        if r > base then
          diplomacy.adjust(a, b, -math.min(R.decay_per_min, r - base), "decay")
        elseif r < base then
          diplomacy.adjust(a, b, math.min(R.decay_per_min, base - r), "decay")
        end
        parts[#parts + 1] = string.format("%s>%s %.0f%s", string.gsub(a, "^rts%-", ""), string.gsub(b, "^rts%-", ""),
          diplomacy.relation(a, b), st and string.sub(st, 1, 1) or "?")
      end
    end
  end
  D.trade_min = {}
  if #parts > 0 then util.log("diplomacy: minute %d: %s", D.minute, table.concat(parts, " ")) end
  if D.minute % 5 == 0 then
    local p = diplomacy.powers()
    local pp = {}
    for _, f in ipairs(nations) do pp[#pp + 1] = string.format("%s %.0f", f, p[f] or 0) end
    util.log("diplomacy: minute %d powers: %s", D.minute, table.concat(pp, ", "))
  end
end

-- Border incidents: supply of other nations' units on f's land (not allies, not at war with f), -5 per 10 supply.
local function border_step(f)
  local D = storage.diplomacy
  local territory = loaded("scripts.territory")
  if not (territory and territory.owner_at) or not alive(f) then return end
  local supply_by = {}
  local skip = B.power.skip_kinds
  for _, rec in pairs(storage.units or {}) do
    local o = rec.force
    if o ~= f and D.index[o] and not skip[rec.kind] and rec.entity.valid then
      local st = get2(D.states, f, o)
      if st == "peace" or st == "ceasefire" then
        if territory.owner_at(rec.entity.position) == f then
          local b = balance.units[rec.entity.name]
          supply_by[o] = (supply_by[o] or 0) + ((b and b.supply) or 1)
        end
      end
    end
  end
  local brow = row(D.border, f)
  for _, o in ipairs(D.forces) do
    local n = supply_by[o] or 0
    brow[o] = n
    if n > 0 then
      diplomacy.adjust(f, o, B.relation.border_per_10_supply * n / 10, "border")
      util.log("diplomacy: border incident: %d supply of %s on %s's land", n, o, f)
    end
  end
end
diplomacy.border_step = border_step

---------------------------------------------------------------------------
-- Damage: "they attacked my units or buildings"
---------------------------------------------------------------------------
local function note_damage(victim, attacker, amount)
  local D = storage.diplomacy
  if not (D.index[victim] and D.index[attacker]) or victim == attacker then return end
  local r = row(D.dmg, victim)
  local h = r[attacker]
  if not h then
    h = {acc = 0, first = game.tick}
    r[attacker] = h
    diplomacy.adjust(victim, attacker, B.relation.attacked_first, "attacked")
  end
  h.acc = h.acc + (amount or 0)
end
diplomacy.note_damage = note_damage

-- The shared on_entity_damaged filter (scripts/research.lua) lists RTS buildings, armored units and the Commander.
events.on(defines.events.on_entity_damaged, function(e)
  local D = storage.diplomacy
  if not (D and D.nation) then return end
  local by, entity = e.force, e.entity
  if not (by and entity and entity.valid) then return end
  note_damage(entity.force.name, by.name, e.final_damage_amount)
end)

-- Deaths of RTS units (not covered by the damage filter): their health counts as damage.
events.on(defines.events.on_entity_died, function(e)
  local D = storage.diplomacy
  if not (D and D.nation) then return end
  local entity, by = e.entity, e.force
  if not (by and entity and entity.valid) then return end
  if not balance.units[entity.name] then return end
  note_damage(entity.force.name, by.name, entity.max_health or 0)
end)

events.on(defines.events.on_force_cease_fire_changed, function() memo_tick = -1 end)
events.on(defines.events.on_force_friends_changed, function() memo_tick = -1 end)

---------------------------------------------------------------------------
-- Match start, scheduler, teardown
---------------------------------------------------------------------------
--- Match start (match.on_started): a Nation match gets its state table, every pair at start_state, relations 0,
--- the city-states at war with everyone. A Skirmish match keeps the empty state (diplomacy.state says "war").
function diplomacy.start_match()
  local D = fresh()
  storage.diplomacy = D
  memo_tick = -1
  local m = storage.match
  if not (m and m.config and m.config.mode == "nation") then return end
  D.nation = true
  for _, f in ipairs(match.forces()) do
    D.forces[#D.forces + 1] = f
    D.index[f] = true
    D.war_ticks[f] = 0
    D.ai[f] = {declined = {}}
  end
  local start = B.start_state
  for _, a in ipairs(D.forces) do
    for _, b in ipairs(D.forces) do
      if a ~= b then
        set2(D.states, a, b, start)
        set2(D.since, a, b, game.tick)
        set2(D.relations, a, b, 0)
      end
    end
  end
  for i, a in ipairs(D.forces) do
    for j = i + 1, #D.forces do apply_engine(a, D.forces[j], start) end
  end
  if game.forces[NEUTRAL] then
    for _, a in ipairs(D.forces) do
      set2(D.states, a, NEUTRAL, "war")
      set2(D.states, NEUTRAL, a, "war")
      set2(D.since, a, NEUTRAL, game.tick)
      set2(D.since, NEUTRAL, a, game.tick)
      apply_engine(a, NEUTRAL, "war")
    end
  end
  util.log("diplomacy: Nation match %d: %d nations at %s, city-states %s (force %s)", m.match_id, #D.forces, start,
    game.forces[NEUTRAL] and "at war with everyone" or "absent", NEUTRAL)
end

match.on_started(function() diplomacy.start_match() end)

match.on_teardown(function()
  local D = storage.diplomacy
  if D and D.nation then
    local s = D.stats
    util.log("diplomacy: teardown: %d proposals (%d accepted, %d declined, %d expired), %d ceasefires, %d peaces, "
      .. "%d alliances, %d refused attacks", s.proposals, s.accepted, s.declined, s.expired, s.ceasefires, s.peaces,
      s.alliances, s.refused_attacks)
  end
  storage.diplomacy = fresh()
  memo_tick = -1
end)

--- Autotest checks of a Nation match (scripts/ai/autotest.lua summary): every pair's engine relations match its state
--- (war = enemies, alliance = friends with shared charts; skipped after the end, when every force ceases fire), and an
--- informational line with the match's diplomacy (wars declared, ceasefires, peaces, alliances, proposals).
function diplomacy.autotest_checks(check)
  local D = storage.diplomacy
  if not (D and D.nation) then return end
  local m = storage.match
  local bad, n = {}, 0
  if m and m.phase ~= "ended" then
    for i, a in ipairs(D.forces) do
      for j = i + 1, #D.forces do
        local b = D.forces[j]
        local fa, fb = game.forces[a], game.forces[b]
        local st = get2(D.states, a, b)
        if fa and fb and st then
          n = n + 1
          local ok = fa.is_enemy(fb) == (st == "war") and fb.is_enemy(fa) == (st == "war")
            and fa.get_friend(fb) == (st == "alliance") and fb.get_friend(fa) == (st == "alliance")
            and (st ~= "alliance" or (fa.share_chart and fb.share_chart))
          if not ok then bad[#bad + 1] = string.format("%s/%s %s", a, b, st) end
        end
      end
    end
  end
  check("diplomacy_engine", #bad == 0, "%d pairs, engine relations %s%s", n, #bad == 0 and "match their states"
    or "differ: ", table.concat(bad, ", "))
  local s = D.stats
  local W = diplomacy.wars
  local treaties = storage.war_meta and storage.war_meta.stats or {treaties = {}}
  check("diplomacy_summary", true, "%d wars declared, %d ended %s; %d ceasefires, %d peaces, %d alliances; %d proposals "
    .. "(%d accepted, %d declined, %d expired); %d attacks refused; minutes at war %s", s.declared,
    treaties.ended or 0, serpent.line(treaties.treaties or {}, {comment = false}), s.ceasefires, s.peaces, s.alliances,
    s.proposals, s.accepted, s.declined, s.expired, s.refused_attacks, serpent.line((function()
      local t = {}
      for _, f in ipairs(D.forces) do t[f] = math.floor((D.war_ticks[f] or 0) / MINUTE) end
      return t
    end)(), {comment = false}))
  return W
end

-- The calm after the end (match.lua ceases fire between the nations): the city-states cease fire too, and proposals
-- that still wait are void.
match.on_ended(function()
  local D = storage.diplomacy
  if not (D and D.nation) then return end
  local n = game.forces[NEUTRAL]
  for _, f in ipairs(D.forces) do
    local ff = game.forces[f]
    if n and ff then
      n.set_cease_fire(ff, true)
      ff.set_cease_fire(n, true)
    end
  end
  for _, P in pairs(D.proposals) do
    if P.status == "pending" then P.status, P.reason, P.answered = "void", "match-over", game.tick end
  end
  memo_tick = -1
end)

-- Slots of the minute: 0 relations, 10 + i border incidents of nation i, 30 + 6 (i - 1) the AI of nation i.
events.on_nth_tick(diplomacy.SLOT, function(e)
  local D = storage.diplomacy
  if not (D and D.nation) then return end
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  answer_due(e.tick)
  local slot = math.floor((e.tick - m.tick_started) / diplomacy.SLOT) % 60
  if slot == 0 then
    if e.tick - m.tick_started >= MINUTE then minute_step() end
    return
  end
  for i, f in ipairs(D.forces) do
    if slot == 10 + i then
      border_step(f)
    elseif diplomacy.AI_SELF_SCHEDULE and slot == (30 + 6 * (i - 1)) % 60 then
      diplomacy.ai_step(f)
    end
  end
end)

return diplomacy
