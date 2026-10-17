-- Phase 5 M2 wars and victory (docs/PHASE5-M2.md §3 "diplomacy.lua / wars.lua", decision D6; study
-- docs/research/scale/war-ai-performance.md §2.8): declarations with goals, war score, weariness, ceasefires,
-- treaties, tribute, and the Nation victory modes. Nation mode only; scripts/diplomacy.lua owns the pair states.
--
--   wars.declare(a, b, goals) -> war_id     goals = {kind = "conquest" | "capital" | "tribute" | "border",
--                                            cities = {city_id, ...}, cr_per_min, minutes}; a resumes a war that is in
--                                            its ceasefire (relation ceasefire_broken)
--   wars.score(war_id) -> {a = n, b = n, weariness = {a = %, b = %}, raw = {a = n, b = n}}   a, b = net war score
--   wars.active(force) -> {war_id, ...}; wars.between(a, b) -> W (active or in ceasefire); wars.get(id)
--   wars.ceasefire(war_id, by); wars.end_war(war_id, treaty)  treaty = {kind = "white"} | {kind = "cede", city_ids,
--                                            to, from} | {kind = "tribute", payer, payee, cr_per_min, minutes} |
--                                            {kind = "eliminated", loser}
--   wars.on_cede(fn)                         load time: fn(city_id, to_force, from_force) flips a ceded city (m2-war's
--                                            capture.flip); without one the cession is only logged
--   wars.victory_step()                      every 10 s: Conquest, Territory, the time limit (Score); reported through
--                                            match.finish_by into match.lua's end-of-match flow
--   wars.nation_score(force) -> n, parts     D6: population + treasury / 10 + land cells + units' supply
--   wars.war_score(force) -> n               net war score over every war of the match (results window)
--   wars.targets(force) -> {{city_id, position, war_id}}   goal cities of its active offensive wars not held yet
--
-- War score (balance.nation.diplomacy.wars): + enemy supply destroyed (1 per supply point), + enemy buildings destroyed
-- (by kind), + city captured (20 + 0.1 per resident; signal "rts_city_captured" {city_id, from, to} from m2-war's
-- capture.flip), + 5 per minute holding the other side's original capital; the net score of a side is its gains minus
-- the other side's. Weariness (%) = supply lost to this enemy in the last 5 minutes / (army + that loss) + 1 per minute
-- of war past 10 minutes + 15 per city lost + 20 while the enemy holds the own capital, clamped to 0..100.
-- A war ends: goals met (treaty by goal: cede the goal cities, tribute), a ceasefire held ceasefire_minutes (white), a
-- side eliminated, max_minutes reached (white), or an accepted peace proposal. After a treaty the AI keeps a truce.
--
-- Victory (D6, lobby: Victory = Conquest | Territory | Score, Time limit = 60 | 90 | 120 | unlimited): Conquest is
-- always on (every nation outside the winner's alliance eliminated or its original capital held by the alliance; an
-- alliance of every remaining nation wins together), Territory adds 45 % of the claimable cells held by an alliance
-- for 3 minutes, or twice the land of the next alliance with at least 3 % (Phase 5 M2 integration), and at the time limit the highest score wins (with its allies; a tie is a draw). Annihilation stays
-- match.lua's fallback.
--
-- Owns storage.wars = {[id] = W} and storage.war_meta = {next_id, first_capital = {[force] = city_id}, holder =
-- {[city_id] = force}, tributes = {...}, territory = {key, since}, minute, stats}; cleared at match teardown.
-- Signals: "rts_war_declared" {war_id}, "rts_war_ended" {war_id, treaty}. Log lines "[rts] war: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local buildings = require("scripts.buildings")
local diplomacy = require("scripts.diplomacy")
local balance = require("balance")

local wars = {}
diplomacy.wars = wars -- diplomacy.lua reaches wars.lua through this (no require loop)

local DB = balance.nation.diplomacy
local WB = DB.wars
local VB = DB.victory
local MINUTE = 60 * 60
local loaded = diplomacy.loaded

wars.GOAL_KINDS = {conquest = true, capital = true, tribute = true, border = true}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function fresh_meta()
  return {next_id = 1, first_capital = {}, holder = {}, tributes = {}, territory = nil, minute = 0,
          stats = {declared = 0, ended = 0, treaties = {}}}
end

local function meta()
  local M = storage.war_meta
  if not M then
    M = fresh_meta()
    storage.war_meta = M
  end
  return M
end

function wars.init()
  storage.wars = storage.wars or {}
  meta()
end

local cede_hooks = {}
--- Load time only: fn(city_id, to_force, from_force) flips a city a treaty cedes (m2-war's capture.flip).
function wars.on_cede(fn) cede_hooks[#cede_hooks + 1] = fn end

local function other(W, f) return W.a == f and W.b or W.a end

local function now_of(W) return W.ended or game.tick end

--- A war record, or nil.
function wars.get(id) return storage.wars and storage.wars[id] or nil end

--- Minutes the war has lasted (until it ended).
function wars.minutes(W)
  if type(W) == "number" then W = wars.get(W) end
  if not W then return 0 end
  return (now_of(W) - W.started) / MINUTE
end

--- The war between a and b that is going on or in its ceasefire, or nil.
function wars.between(a, b)
  for _, W in pairs(storage.wars or {}) do
    if W.status ~= "ended" and ((W.a == a and W.b == b) or (W.a == b and W.b == a)) then return W end
  end
  return nil
end

--- Ids of the wars of a force that are going on or in their ceasefire, oldest first.
function wars.active(force)
  local out = {}
  for id, W in pairs(storage.wars or {}) do
    if W.status ~= "ended" and (W.a == force or W.b == force) then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

--- Every war of the match (ids, oldest first).
function wars.all()
  local out = {}
  for id in pairs(storage.wars or {}) do out[#out + 1] = id end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Cities, capitals
---------------------------------------------------------------------------
local function city(id)
  local cities = loaded("scripts.cities")
  return cities and cities.get(id) or nil
end

--- Who holds a city: the last capture this module saw ("rts_city_captured"), else the city record's force.
function wars.holder(city_id)
  local h = meta().holder[city_id]
  if h then return h end
  local c = city(city_id)
  return c and c.force or nil
end

local function capital_of(f)
  local n = storage.nations and storage.nations[f]
  return n and n.capital or nil
end

local function first_capital(f)
  local M = meta()
  local id = M.first_capital[f]
  if not id then
    id = capital_of(f)
    M.first_capital[f] = id
  end
  return id
end
wars.first_capital = first_capital

local function out_of_match(f)
  local m = storage.match
  return m and m.out and m.out[f] ~= nil
end

--- Eliminated: out of the match, or (with cities) no city left of a nation that had a capital.
function wars.eliminated(f)
  if out_of_match(f) then return true end
  local cities = loaded("scripts.cities")
  if not cities then return false end
  if not meta().first_capital[f] then return false end
  return #cities.for_force(f) == 0
end

local function city_name(id)
  local cities = loaded("scripts.cities")
  local c = cities and cities.get(id)
  if c and cities.display_name then return cities.display_name(c) end
  return {"rts.war-city-number", id}
end

local function city_list_text(ids)
  local t = {""}
  for i, id in ipairs(ids or {}) do
    if i > 1 then t[#t + 1] = ", " end
    if #t >= 18 then
      t[#t + 1] = "..."
      break
    end
    t[#t + 1] = city_name(id)
  end
  return t
end

---------------------------------------------------------------------------
-- Goals and treaties
---------------------------------------------------------------------------
local function nearest_city(a, b)
  local g = diplomacy.ai_goals(a, b)
  return g.cities and g.cities[1] or capital_of(b)
end

local function normalize_goals(a, b, goals)
  goals = goals or {}
  local kind = goals.kind
  if kind == nil and goals.cities then kind = "conquest" end
  if not wars.GOAL_KINDS[kind] then kind = "conquest" end
  local g = {kind = kind}
  if kind == "conquest" or kind == "border" then
    g.cities = {}
    for _, id in ipairs(goals.cities or {}) do g.cities[#g.cities + 1] = id end
    if kind == "conquest" and #g.cities == 0 then g.cities = {nearest_city(a, b)} end
    g.region = goals.region
  elseif kind == "capital" then
    g.city = goals.city or capital_of(b)
  elseif kind == "tribute" then
    g.cr_per_min = goals.cr_per_min or WB.tribute.cr_per_min
    g.minutes = goals.minutes or WB.tribute.minutes
  end
  return g
end

--- The goals of a war as a localised string.
function wars.goal_text(W)
  local g = W.goals or {}
  if g.kind == "conquest" then return {"rts.war-goal-conquest", city_list_text(g.cities)} end
  if g.kind == "capital" then return {"rts.war-goal-capital", g.city and city_name(g.city) or {"rts.war-city-none"},
                                      WB.capital_hold_minutes} end
  if g.kind == "tribute" then return {"rts.war-goal-tribute", g.cr_per_min or 0, g.minutes or 0, WB.tribute.score} end
  if g.kind == "border" then
    if g.cities and #g.cities > 0 then return {"rts.war-goal-border-cities", city_list_text(g.cities)} end
    return {"rts.war-goal-border", WB.border_score}
  end
  return {"rts.war-goal-none"}
end

--- A treaty as a localised string.
function wars.treaty_text(t)
  t = t or {}
  if t.kind == "cede" then return {"rts.war-treaty-cede", city_list_text(t.city_ids), diplomacy.label(t.to or "?")} end
  if t.kind == "tribute" then
    return {"rts.war-treaty-tribute", diplomacy.label(t.payer or "?"), t.cr_per_min or 0, t.minutes or 0}
  end
  if t.kind == "eliminated" then return {"rts.war-treaty-eliminated", diplomacy.label(t.loser or "?")} end
  if t.kind == "timeout" then return {"rts.war-treaty-timeout"} end
  return {"rts.war-treaty-white"}
end

local function held_by_side(city_id, f)
  local h = wars.holder(city_id)
  return h ~= nil and (h == f or diplomacy.allied(h, f))
end

--- True when the attacker met the war's goals.
function wars.goals_met(W)
  local g = W.goals or {}
  if g.kind == "conquest" or (g.kind == "border" and g.cities and #g.cities > 0) then
    if not g.cities or #g.cities == 0 then return false end
    for _, id in ipairs(g.cities) do
      if not held_by_side(id, W.a) then return false end
    end
    return true
  elseif g.kind == "capital" then
    return W.capital_held_since ~= nil and game.tick - W.capital_held_since >= WB.capital_hold_minutes * MINUTE
  elseif g.kind == "tribute" then
    return wars.net_score(W, W.a) >= WB.tribute.score
  elseif g.kind == "border" then
    return wars.net_score(W, W.a) >= WB.border_score
  end
  return false
end

local function treaty_for_goals(W)
  local g = W.goals or {}
  if g.kind == "conquest" or g.kind == "border" then
    return {kind = "cede", city_ids = g.cities or {}, to = W.a, from = W.b}
  elseif g.kind == "capital" then
    return {kind = "cede", city_ids = {g.city}, to = W.a, from = W.b}
  elseif g.kind == "tribute" then
    return {kind = "tribute", payer = W.b, payee = W.a, cr_per_min = g.cr_per_min, minutes = g.minutes}
  end
  return {kind = "white"}
end

---------------------------------------------------------------------------
-- Score and weariness
---------------------------------------------------------------------------
--- Net war score of side f: its gains minus the other side's.
function wars.net_score(W, f)
  local o = other(W, f)
  return (W.gains[f] or 0) - (W.gains[o] or 0)
end

local function army_supply(f)
  local supply = loaded("scripts.supply")
  if supply and supply.used then return supply.used(f) end
  return 0
end

--- Weariness of side f in war W, 0..100 (%).
function wars.weariness(W, f)
  if type(W) == "number" then W = wars.get(W) end
  if not W or not W.lost[f] then return 0 end
  local Wr = WB.weariness
  local lost = 0
  for _, n in ipairs(W.lost[f]) do lost = lost + n end
  local army = army_supply(f)
  local L = 100 * lost / math.max(1, army + lost)
  local Dur = math.max(0, wars.minutes(W) - Wr.grace_minutes) * Wr.per_minute
  local Cty = (W.cities_lost[f] or 0) * Wr.per_city
  local cap = first_capital(f)
  local Cap = (cap and wars.holder(cap) == other(W, f)) and Wr.capital or 0
  return math.max(0, math.min(100, L + Dur + Cty + Cap))
end

--- {a = net, b = net, weariness = {a = %, b = %}, raw = {a = gains, b = gains}} of a war.
function wars.score(id)
  local W = type(id) == "table" and id or wars.get(id)
  if not W then return nil end
  return {a = wars.net_score(W, W.a), b = wars.net_score(W, W.b),
          weariness = {a = wars.weariness(W, W.a), b = wars.weariness(W, W.b)},
          raw = {a = W.gains[W.a] or 0, b = W.gains[W.b] or 0}}
end

--- Net war score of a force over every war of the match.
function wars.war_score(f)
  local n = 0
  for _, W in pairs(storage.wars or {}) do
    if W.a == f or W.b == f then n = n + wars.net_score(W, f) end
  end
  return n
end

local function population_of(f)
  local cities = loaded("scripts.cities")
  local population = loaded("scripts.population")
  local n = 0
  for _, c in ipairs(cities and cities.for_force(f) or {}) do
    local p = population and population.of and population.of(c.id)
    if p and p.pop then
      n = n + p.pop
    else
      n = n + (WB.city_pop_fallback[c.tier or 1] or 0)
    end
  end
  return n
end

--- D6 score of a nation and its parts {pop, treasury, land, supply}.
function wars.nation_score(f)
  local treasury = loaded("scripts.treasury")
  local territory = loaded("scripts.territory")
  local t = treasury and treasury.get and treasury.get(f)
  local parts = {pop = population_of(f), treasury = t and (t.balance or 0) / 10 or 0,
                 land = territory and territory.cells and territory.cells(f) or 0, supply = army_supply(f)}
  return math.floor(parts.pop + parts.treasury + parts.land + parts.supply + 0.5), parts
end

---------------------------------------------------------------------------
-- Declarations, ceasefires, treaties
---------------------------------------------------------------------------
local function new_war(a, b, goals)
  local M = meta()
  local id = M.next_id
  M.next_id = id + 1
  local W = {id = id, a = a, b = b, goals = goals, started = game.tick, status = "active",
             gains = {[a] = 0, [b] = 0}, lost = {[a] = {0, 0, 0, 0, 0}, [b] = {0, 0, 0, 0, 0}}, bucket = 1,
             cities_lost = {[a] = 0, [b] = 0}, captured = {}, capital_minutes = {[a] = 0, [b] = 0}}
  storage.wars[id] = W
  return W
end

local function human_alert(to, kind, text, params, about)
  diplomacy.alert(to, kind, text, params, about)
end

--- Declare war: a on b with goals (normalised; see the header). Returns the war id, or nil and a reason.
function wars.declare(a, b, goals)
  if not diplomacy.nation() then return nil, "not-nation" end
  if a == b or not (diplomacy.is_nation(a) and diplomacy.is_nation(b)) then return nil, "unknown-nation" end
  if out_of_match(a) or out_of_match(b) then return nil, "eliminated" end
  local st = diplomacy.state(a, b)
  if st == "war" then return nil, "already-at-war" end
  if st == "alliance" then return nil, "allied" end
  local R = DB.relation
  local W = wars.between(a, b) -- a war in its ceasefire resumes
  local resumed = W ~= nil
  if W then
    W.status, W.cf_tick, W.cf_by = "active", nil, nil
    W.resumed = (W.resumed or 0) + 1
    diplomacy.adjust(b, a, R.ceasefire_broken, "ceasefire-broken")
  else
    W = new_war(a, b, normalize_goals(a, b, goals))
  end
  local Dg = storage.diplomacy
  if Dg.truce[a] then Dg.truce[a][b] = nil end
  if Dg.truce[b] then Dg.truce[b][a] = nil end
  diplomacy.set_state(a, b, "war", (resumed and "war resumed by " or "war declared by ") .. a, {silent = true})
  diplomacy.adjust(b, a, R.declared_on, "declared")
  for _, o in ipairs(diplomacy.nations()) do
    if o ~= a and o ~= b and diplomacy.state(o, b) ~= "war" then diplomacy.adjust(o, a, R.declared_others, "aggression") end
  end
  first_capital(a)
  first_capital(b)
  local M = meta()
  M.stats.declared = M.stats.declared + 1
  Dg.stats.declared = Dg.stats.declared + 1
  local goal = wars.goal_text(W)
  human_alert(b, "diplomacy-war", "rts.war-alert-declared-on-you", {diplomacy.label(a), goal}, a)
  human_alert(a, "diplomacy-war", "rts.war-alert-declared", {diplomacy.label(b), goal}, b)
  for _, o in ipairs(diplomacy.nations()) do
    if o ~= a and o ~= b then
      human_alert(o, "diplomacy-news", "rts.war-alert-declared-other", {diplomacy.label(a), diplomacy.label(b)}, b)
    end
  end
  util.log("war: #%d %s %s -> %s at %.0fs, goals %s", W.id, resumed and "resumed" or "declared", a, b,
    match.elapsed_seconds(), serpent.line(W.goals, {comment = false}))
  events.emit("rts_war_declared", {war_id = W.id, resumed = resumed})
  return W.id
end

--- The war goes into its ceasefire (both sides cease fire; peace after ceasefire_minutes unless it resumes).
function wars.ceasefire(id, by)
  local W = wars.get(id)
  if not (W and W.status == "active") then return false, "not-active" end
  W.status, W.cf_tick, W.cf_by = "ceasefire", game.tick, by
  diplomacy.set_state(W.a, W.b, "ceasefire", "ceasefire in war #" .. id)
  util.log("war: #%d ceasefire (%s) after %.1f min, score %s", id, tostring(by), wars.minutes(W),
    serpent.line(wars.score(W), {comment = false}))
  return true
end

local function apply_cede(t, W)
  local ids = t.city_ids or {}
  for _, id in ipairs(ids) do
    local holder = wars.holder(id)
    if holder ~= t.to then
      if #cede_hooks == 0 then
        util.log("war: treaty cedes city %s from %s to %s: no capture hook (m2-war capture.flip), logged only",
          tostring(id), tostring(holder or t.from), tostring(t.to))
      else
        for _, fn in ipairs(cede_hooks) do fn(id, t.to, holder or t.from) end
        meta().holder[id] = t.to -- the hook flips it (its "rts_city_captured" sets the holder again)
        util.log("war: treaty cedes city %s from %s to %s (capture hook called)", tostring(id), tostring(holder or t.from),
          tostring(t.to))
      end
    else
      util.log("war: treaty confirms city %s to %s (captured in war #%d)", tostring(id), tostring(t.to), W.id)
    end
  end
end

local function add_tribute(t)
  if not (t.payer and t.payee and (t.cr_per_min or 0) > 0 and (t.minutes or 0) > 0) then return end
  local list = meta().tributes
  list[#list + 1] = {payer = t.payer, payee = t.payee, cr_per_min = t.cr_per_min, left = t.minutes,
                     next_tick = game.tick + MINUTE, paid = 0}
end

--- End a war with a treaty (see the header). Returns true.
function wars.end_war(id, treaty)
  local W = wars.get(id)
  if not W or W.status == "ended" then return false, "not-active" end
  treaty = treaty or {kind = "white"}
  W.status, W.ended, W.treaty = "ended", game.tick, treaty
  if treaty.kind == "cede" then
    apply_cede(treaty, W)
  elseif treaty.kind == "tribute" then
    add_tribute(treaty)
  end
  local M = meta()
  M.stats.ended = M.stats.ended + 1
  M.stats.treaties[treaty.kind or "white"] = (M.stats.treaties[treaty.kind or "white"] or 0) + 1
  diplomacy.set_state(W.a, W.b, "peace", "treaty of war #" .. id, {silent = true})
  local Dg = storage.diplomacy
  local truce = game.tick + DB.truce_minutes * MINUTE
  Dg.truce[W.a] = Dg.truce[W.a] or {}
  Dg.truce[W.b] = Dg.truce[W.b] or {}
  Dg.truce[W.a][W.b], Dg.truce[W.b][W.a] = truce, truce
  local text = wars.treaty_text(treaty)
  human_alert(W.a, "diplomacy-peace", "rts.war-alert-ended", {diplomacy.label(W.b), text}, W.b)
  human_alert(W.b, "diplomacy-peace", "rts.war-alert-ended", {diplomacy.label(W.a), text}, W.a)
  local s = wars.score(W)
  util.log("war: #%d %s / %s ended after %.1f min: treaty %s, score %s %.0f / %s %.0f, weariness %.0f%% / %.0f%%", id,
    W.a, W.b, wars.minutes(W), serpent.line(treaty, {comment = false}), W.a, s.a, W.b, s.b, s.weariness.a,
    s.weariness.b)
  events.emit("rts_war_ended", {war_id = id, treaty = treaty})
  return true
end

--- Goal cities of a force's active offensive wars that it does not hold yet: {{city_id, position, war_id}}.
function wars.targets(f)
  local out = {}
  for _, id in ipairs(wars.active(f)) do
    local W = wars.get(id)
    if W.a == f and W.status == "active" then
      local g = W.goals or {}
      local ids = g.cities or (g.city and {g.city}) or {}
      for _, cid in ipairs(ids) do
        local c = city(cid)
        if c and not held_by_side(cid, f) then out[#out + 1] = {city_id = cid, position = c.position, war_id = id} end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Events: losses, captures
---------------------------------------------------------------------------
local function active_between(a, b)
  local W = wars.between(a, b)
  return (W and W.status == "active") and W or nil
end

events.on(defines.events.on_entity_died, function(e)
  if not diplomacy.nation() then return end
  local entity, by = e.entity, e.force
  if not (entity and entity.valid and by) then return end
  local name = entity.name
  local unit = balance.units[name]
  local kind = not unit and buildings.KIND_BY_NAME[name] or nil
  if not (unit or kind) then return end
  local v, k = entity.force.name, by.name
  if v == k then return end
  local W = active_between(k, v)
  if not W then return end
  if unit then
    local cost = unit.supply or 1
    local ring = W.lost[v]
    ring[W.bucket] = ring[W.bucket] + cost
    W.gains[k] = W.gains[k] + cost * WB.unit_supply
  else
    W.gains[k] = W.gains[k] + (WB.building[kind] or WB.building.default)
  end
end)

local function city_points(city_id)
  local population = loaded("scripts.population")
  local p = population and population.of and population.of(city_id)
  local pop = p and p.pop
  if not pop then
    local c = city(city_id)
    pop = WB.city_pop_fallback[(c and c.tier) or 1] or 0
  end
  return WB.city + WB.city_per_pop * pop
end

-- m2-war's capture.flip emits this when a city changes hands (tests raise it by script).
events.on_signal("rts_city_captured", function(d)
  if not (d and d.city_id) or not diplomacy.nation() then return end
  local M = meta()
  M.holder[d.city_id] = d.to
  local W = (d.from and d.to) and wars.between(d.to, d.from) or nil
  util.log("war: city %s captured by %s from %s%s", tostring(d.city_id), tostring(d.to), tostring(d.from),
    W and string.format(" (war #%d)", W.id) or " (no war between them)")
  if not W then return end
  local pts = city_points(d.city_id)
  W.gains[d.to] = (W.gains[d.to] or 0) + pts
  if W.cities_lost[d.from] then W.cities_lost[d.from] = W.cities_lost[d.from] + 1 end
  W.captured[#W.captured + 1] = {city = d.city_id, by = d.to, tick = game.tick}
end)

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local function pay_tributes()
  local M = meta()
  local treasury = loaded("scripts.treasury")
  local keep = {}
  for _, T in ipairs(M.tributes) do
    if game.tick >= T.next_tick then
      T.next_tick = T.next_tick + MINUTE
      T.left = T.left - 1
      if treasury and treasury.charge and treasury.add then
        if treasury.charge(T.payer, T.cr_per_min, "tribute") then
          treasury.add(T.payee, T.cr_per_min, "tribute")
          T.paid = T.paid + T.cr_per_min
          util.log("war: tribute %s -> %s %d cr (%d minutes left)", T.payer, T.payee, T.cr_per_min, T.left)
        else
          util.log("war: tribute %s -> %s %d cr not paid (treasury refused)", T.payer, T.payee, T.cr_per_min)
        end
      else
        util.log("war: tribute %s -> %s %d cr (no treasury: logged only, %d minutes left)", T.payer, T.payee,
          T.cr_per_min, T.left)
      end
    end
    if T.left > 0 and not out_of_match(T.payer) then keep[#keep + 1] = T end
  end
  M.tributes = keep
end

-- Once per match minute: weariness buckets, capital holding (score, goal timer), tributes.
local function minute_step()
  for _, W in pairs(storage.wars or {}) do
    if W.status == "active" then
      W.bucket = W.bucket % WB.weariness.window_minutes + 1
      W.lost[W.a][W.bucket], W.lost[W.b][W.bucket] = 0, 0
      for _, side in ipairs({W.a, W.b}) do
        local cap = first_capital(other(W, side))
        if cap and held_by_side(cap, side) then
          W.gains[side] = W.gains[side] + WB.capital_per_min
          W.capital_minutes[side] = (W.capital_minutes[side] or 0) + 1
        end
      end
    end
  end
  pay_tributes()
end

-- Every 10 s: ceasefires turning into peace, goals, eliminations, timeouts, stray states.
local function war_step()
  local tick = game.tick
  local cf_ticks = DB.ceasefire_minutes * MINUTE
  for id, W in pairs(storage.wars or {}) do
    if W.status ~= "ended" then
      local st = diplomacy.state(W.a, W.b)
      if W.status == "ceasefire" then
        if st == "war" then
          W.status, W.cf_tick = "active", nil
        elseif st ~= "ceasefire" then
          wars.end_war(id, {kind = "white"})
        elseif tick - W.cf_tick >= cf_ticks then
          wars.end_war(id, {kind = "white"})
        end
      elseif W.status == "active" then
        if wars.eliminated(W.a) or wars.eliminated(W.b) then
          wars.end_war(id, {kind = "eliminated", loser = wars.eliminated(W.b) and W.b or W.a})
        elseif st == "ceasefire" then
          W.status, W.cf_tick = "ceasefire", tick
        elseif st ~= "war" then
          wars.end_war(id, {kind = "white"})
        else
          local g = W.goals or {}
          if g.kind == "capital" then
            if g.city and held_by_side(g.city, W.a) then
              W.capital_held_since = W.capital_held_since or tick
            else
              W.capital_held_since = nil
            end
          end
          if wars.goals_met(W) then
            util.log("war: #%d goals met by %s (%s)", id, W.a, serpent.line(g, {comment = false}))
            wars.end_war(id, treaty_for_goals(W))
          elseif wars.minutes(W) >= WB.max_minutes then
            wars.end_war(id, {kind = "timeout"})
          end
        end
      end
    end
  end
  -- a ceasefire without a war record (start_state = "war" matches) becomes peace after the same time
  local Dg = storage.diplomacy
  for _, a in ipairs(diplomacy.nations()) do
    for _, b in ipairs(diplomacy.nations()) do
      if a < b and Dg.states[a] and Dg.states[a][b] == "ceasefire" and not wars.between(a, b) then
        local since = Dg.since[a] and Dg.since[a][b] or tick
        if tick - since >= cf_ticks then diplomacy.set_state(a, b, "peace", "ceasefire held") end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Victory (D6)
---------------------------------------------------------------------------
local function alive_nations()
  local out = {}
  for _, f in ipairs(diplomacy.nations()) do
    if not wars.eliminated(f) then out[#out + 1] = f end
  end
  return out
end

local function coalition(x, alive)
  local set, list = {[x] = true}, {x}
  for _, o in ipairs(alive) do
    if o ~= x and diplomacy.allied(x, o) then
      set[o] = true
      list[#list + 1] = o
    end
  end
  return set, list
end

local function conquered(r, coal)
  local cap = first_capital(r)
  if not cap then return false end
  local h = wars.holder(cap)
  return h ~= nil and coal[h] == true
end

local function finish(list, how, detail)
  util.log("war: victory %s: %s (%s) at %.0fs", how, table.concat(list, ", "), tostring(detail), match.elapsed_seconds())
  if match.finish_by then return match.finish_by(list, how, detail) end
  return false
end

--- Victory conditions of a Nation match (every VB.step_ticks). Returns the victory kind when the match ended.
function wars.victory_step()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started and diplomacy.nation()) then return nil end
  local c = m.config or {}
  local alive = alive_nations()
  if #alive == 0 then return nil end
  -- Conquest (always): every nation outside x's alliance eliminated or its original capital held by the alliance
  for _, x in ipairs(alive) do
    local coal, list = coalition(x, alive)
    local ok, outside, held = true, 0, 0
    for _, r in ipairs(diplomacy.nations()) do
      if not coal[r] then
        outside = outside + 1
        if not wars.eliminated(r) then
          if not conquered(r, coal) then
            ok = false
            break
          end
          held = held + 1
        end
      end
    end
    if ok and (outside > 0 or #list == #alive) then
      local how = outside > 0 and "conquest" or "alliance"
      finish(list, how, outside > 0 and string.format("%d rivals eliminated, %d capitals held", outside - held, held)
        or "every remaining nation allied")
      return how
    end
  end
  -- Territory: an alliance holds VB.territory_share of the claimable cells for VB.territory_minutes.
  -- Phase 5 M2 integration: or VB.territory_lead times the land of the next coalition, with at least
  -- VB.territory_lead_min of the claimable cells (four nations of ten cities own about 20 % of a 2048 world, so a share
  -- alone is out of reach before the late game; the lead rule lets a conqueror win).
  local M = meta()
  if c.victory == "territory" or c.victory == "any" then -- Phase 5 M3 age3: Any includes Territory
    local territory = loaded("scripts.territory")
    local coals, seen = {}, {}
    for _, x in ipairs(alive) do
      local _, list = coalition(x, alive)
      table.sort(list)
      local key = table.concat(list, "+")
      if not seen[key] then
        seen[key] = true
        local share = 0
        for _, f in ipairs(list) do share = share + (territory and territory.share and territory.share(f) or 0) end
        coals[#coals + 1] = {key = key, list = list, share = share}
      end
    end
    local best, best_share, best_list
    for _, k in ipairs(coals) do
      local next_share = 0
      for _, o in ipairs(coals) do
        if o.key ~= k.key and o.share > next_share then next_share = o.share end
      end
      k.next = next_share
      local lead = k.share >= (VB.territory_lead_min or 1) and k.share >= (VB.territory_lead or math.huge) * next_share
      if (k.share >= VB.territory_share or lead) and (not best_share or k.share > best_share) then
        best, best_share, best_list = k.key, k.share, k.list
      end
    end
    if best then
      if not (M.territory and M.territory.key == best) then
        M.territory = {key = best, since = game.tick}
        util.log("war: territory %s holds %.1f %% (victory after %d minutes)", best, best_share * 100, VB.territory_minutes)
      elseif game.tick - M.territory.since >= VB.territory_minutes * MINUTE then
        finish(best_list, "territory", string.format("%.1f %% for %d s", best_share * 100,
          (game.tick - M.territory.since) / 60))
        return "territory"
      end
    elseif M.territory then
      util.log("war: territory lead of %s lost", M.territory.key)
      M.territory = nil
    end
  end
  -- Score at the time limit
  local limit = c.time_limit or 0
  if limit > 0 and match.elapsed_seconds() >= limit * 60 then
    local best, best_score, tie
    for _, f in ipairs(alive) do
      local s = wars.nation_score(f)
      if not best_score or s > best_score then
        best, best_score, tie = f, s, false
      elseif s == best_score and not diplomacy.allied(f, best) then
        tie = true
      end
    end
    if tie then
      finish({}, "score", "a tie at the time limit")
    else
      local _, list = coalition(best, alive)
      finish(list, "score", string.format("%s %d at the %d-minute limit", best, best_score, limit))
    end
    return "score"
  end
  return nil
end

events.on_nth_tick(VB.step_ticks, function(e)
  if not diplomacy.nation() then return end
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local M = meta()
  local minute = math.floor((e.tick - m.tick_started) / MINUTE)
  if minute > (M.minute or 0) then
    M.minute = minute
    minute_step()
  end
  war_step()
  wars.victory_step()
end)

---------------------------------------------------------------------------
-- Match start and teardown
---------------------------------------------------------------------------
match.on_started(function()
  storage.wars = {}
  storage.war_meta = fresh_meta()
  if not diplomacy.nation() then return end
  for _, f in ipairs(diplomacy.nations()) do first_capital(f) end
  local c = storage.match.config or {}
  util.log("war: Nation match: victory %s, time limit %s", tostring(c.victory or VB.default_mode),
    (c.time_limit or 0) > 0 and (c.time_limit .. " min") or "none")
end)

match.on_teardown(function()
  local M = storage.war_meta
  if M and M.stats and M.stats.declared > 0 then
    util.log("war: teardown: %d wars declared, %d ended %s", M.stats.declared, M.stats.ended,
      serpent.line(M.stats.treaties, {comment = false}))
  end
  storage.wars = {}
  storage.war_meta = fresh_meta()
end)

return wars
