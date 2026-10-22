-- Phase 5 M3 ai (docs/PHASE5-M3.md D7, §3 "ai/controller.lua"; study docs/research/scale/war-ai-performance.md §4.1):
-- division controllers of an AI nation. Nation mode only; ai/commander.lua calls controller.run(C) in slice 3 of every
-- run (every 60 ticks per nation): the nation's AI divisions in turn, at most balance.nation.ai3.controller.per_tick
-- of them per call (a cursor goes round), each at most once per controller.period ticks.
--
--   controller.step(division_id) -> what it did ("retreat" | "return" | "resupply" | "stance" | nil)
--   controller.run(C)
--
-- Per division (orders count against the difficulty's orders per minute, `opm`):
--   planes     an all-plane division whose planes average below plane_supply supply flies home (air.order_return)
--   stance     attack groups advance, holding divisions hold, groups on their way home screen
--   retreat    (micro basic and full) an attacking group whose force ratio (own supply x health against the hostile
--              supply in sight within enemy_radius) falls below retreat_ratio is recalled (army.recall): the operation
--              turns to "return"
--   resupply   a division that is not attacking and is out of supply (warsupply) walks to the nearest own depot when
--              no enemy is near
-- State: storage.nations[force].council.ctl = {cursor, [division id] = {next, orders = {tick, ...}}}.
-- Log lines "[rts] council: <force> controller ...".
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")
local buildings = require("scripts.buildings")
local difficulty = require("scripts.ai.difficulty")
local army = require("scripts.ai.army")
local balance = require("balance")

local controller = {}

local CTL = balance.nation.ai3.controller
local AIR_KIND = {["scout-plane"] = true, bomber = true, interceptor = true}

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function supply_of(name)
  local u = balance.units[name]
  return u and u.supply or 1
end

local function state_of(force_name)
  local N = storage.nations and storage.nations[force_name]
  local K = N and N.council
  if not K then return nil end
  K.ctl = K.ctl or {cursor = 0}
  return K.ctl
end

-- The army group (and its id) a division belongs to, or nil.
local function group_of(C, div)
  local a = C.army
  if not a then return nil end
  for gid, G in pairs(a.groups) do
    if G.division == div then return G, gid end
  end
  return nil
end

-- Orders this minute within the difficulty's opm: true (and counted) when one more is allowed.
local function may_order(force_name, rec)
  local opm = difficulty.knobs(force_name).opm
  local now = game.tick
  local keep = {}
  for _, t in ipairs(rec.orders or {}) do
    if now - t < 3600 then keep[#keep + 1] = t end
  end
  rec.orders = keep
  if #keep >= opm then return false end
  keep[#keep + 1] = now
  return true
end

-- Hostile supply in sight around `pos` (the division's own members see it: honest).
local function hostile_supply(force_name, surface, pos, radius)
  local n = 0
  local hostile = {}
  for _, e in ipairs(surface.find_entities_filtered({position = pos, radius = radius, type = {"unit", "spider-unit"},
                                                     limit = 300})) do
    if e.valid then
      local f = e.force.name
      if f ~= force_name then
        if hostile[f] == nil then hostile[f] = diplomacy.hostile(force_name, f) end
        if hostile[f] and e.unit_number and storage.units and storage.units[e.unit_number] then
          n = n + supply_of(e.name) * (e.get_health_ratio() or 1)
        end
      end
    end
  end
  return n
end

local function own_supply(D)
  local n = 0
  for un in pairs(D.units) do
    local rec = units.get(un)
    if rec and rec.entity.valid then n = n + supply_of(rec.entity.name) * (rec.entity.get_health_ratio() or 1) end
  end
  return n
end

local function all_planes(D)
  local any = false
  for un in pairs(D.units) do
    local rec = units.get(un)
    if rec then
      if not AIR_KIND[rec.kind] then return false end
      any = true
    end
  end
  return any
end

--- One controller look at an AI division. Returns what it did, or nil.
function controller.step(division_id)
  local D = divisions.get(division_id)
  if not (D and D.owner == "ai" and nation_mode()) then return nil end
  local C = storage.ai and storage.ai[D.force]
  local ctl = state_of(D.force)
  if not (C and ctl) then return nil end
  local rec = ctl[division_id]
  if not rec then
    rec = {next = 0, orders = {}}
    ctl[division_id] = rec
  end
  if game.tick < rec.next then return nil end
  rec.next = game.tick + CTL.period
  local n = divisions.strength(D)
  if n == 0 then return nil end
  local surface = util.surface()
  -- planes: home before the tank runs dry (air.lua's bingo rule is the safety net)
  if all_planes(D) then
    local air = mod("air")
    if not (air and air.supply and air.state) then return nil end
    local sum, cnt, flying = 0, 0, false
    for un in pairs(D.units) do
      sum, cnt = sum + (air.supply(un) or 100), cnt + 1
      if air.state(un) == "flying" then flying = true end
    end
    if flying and cnt > 0 and sum / cnt < CTL.plane_supply and may_order(D.force, rec) then
      air.order_return(division_id)
      util.log("council: %s controller: division #%d planes at %.0f supply fly home", D.force, division_id, sum / cnt)
      return "return"
    end
    return nil
  end
  local G, gid = group_of(C, division_id)
  -- stance by role
  local want
  if G and G.state == "attack" then
    want = "advance"
  elseif G and (G.state == "retreat" or G.state == "return") then
    want = "screen"
  elseif C.army and C.army.held and next(D.units) and C.army.held[next(D.units)] == division_id then
    want = "hold"
  end
  if want and D.stance ~= want and divisions.set_stance then
    divisions.set_stance(division_id, want)
  end
  if not (D.pos and surface) then return nil end
  -- retreat by force ratio (micro basic and full)
  if G and G.state == "attack" and difficulty.micro(D.force, "basic") then
    local enemy = hostile_supply(D.force, surface, D.pos, CTL.enemy_radius)
    if enemy > 0 then
      local own = own_supply(D)
      if own / enemy < CTL.retreat_ratio and may_order(D.force, rec) and army.recall then
        army.recall(C, gid, string.format("force ratio %.2f (%.0f against %.0f)", own / enemy, own, enemy), "retreat")
        C.stats.ratio_retreats = (C.stats.ratio_retreats or 0) + 1
        return "retreat"
      end
    end
  end
  -- resupply: a division that is not attacking and is out of supply walks to the nearest own depot
  local ws = mod("warsupply")
  if ws and ws.state and not (G and G.state == "attack") and difficulty.micro(D.force, "basic") then
    local st = ws.state(division_id)
    if (st == "out" or st == "low") and D.state ~= "moving" and hostile_supply(D.force, surface, D.pos, 40) == 0 then
      local best, bd
      for _, un in ipairs(ws.depots(D.force) or {}) do
        local b = buildings.get(un)
        if b then
          local d = util.distance(b.position, D.pos)
          if not bd or d < bd then best, bd = b, d end
        end
      end
      if best and bd > 20 and may_order(D.force, rec) then
        divisions.order(division_id, "move", best.position, {auto = "resupply"})
        util.log("council: %s controller: division #%d (%s supply) walks to depot #%d (%.0f tiles)", D.force,
          division_id, st, best.entity.unit_number, bd)
        return "resupply"
      end
    end
  end
  return nil
end

--- The nation's AI divisions in turn (ai/commander.lua, slice 3 of every run).
function controller.run(C)
  if not nation_mode() then return end
  local ctl = state_of(C.force)
  if not ctl then return end
  local list = divisions.for_force(C.force)
  local ids = {}
  for _, D in ipairs(list) do
    if D.owner == "ai" then ids[#ids + 1] = D.id end
  end
  table.sort(ids)
  -- forget the records of divisions that are gone
  local live = {}
  for _, id in ipairs(ids) do live[id] = true end
  for k in pairs(ctl) do
    if type(k) == "number" and not live[k] then ctl[k] = nil end
  end
  if #ids == 0 then return end
  local per = CTL.per_tick
  local start = ctl.cursor % #ids
  for i = 1, math.min(per, #ids) do
    controller.step(ids[(start + i - 1) % #ids + 1])
  end
  ctl.cursor = start + math.min(per, #ids)
end

return controller
