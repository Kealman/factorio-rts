-- Phase 5 M3 age3: rare resources (docs/PHASE5-M3.md D3, §3 "age3.lua / rare.lua / sinks.lua"; study
-- docs/research/scale/deep-economy.md §3.7; notes docs/qa/phase5-age3-notes.md). Nation mode only.
--
--   rare.deposits(force) -> {{kind, position, extractor (LuaEntity | nil), flowing = bool, last_tick}}
--   rare.bonuses(force) -> {[kind] = {active = bool, since, last_tick, arrived}}   the applied bonus set
--   rare.apply(force)    recompute the force modifiers from the active set (deltas against what this module applied)
--   rare.kind_of(item_or_entity_name) -> kind | nil;  rare.describe(force) -> one log line
--
-- Extractors. The rare extractor (prototypes/age3.lua: a drill on the rts-rare category, one item every item_seconds, no
-- mining productivity, no power; Geology unlocks it, it may stand on own or neutral land) drops its item on the ground
-- at its drop position; every pickup_period ticks this module moves it into the logistic network the extractor
-- stands in (an extractor without a network keeps up to `buffer` items, then stops). The items travel like any good
-- (haulers, trains, export policies).
--
-- Flow and bonus. Every check_period ticks the capital's network (the capital City Center's) gives up every rare item
-- that reached it: an arrival keeps that kind's bonus on for `grace` seconds, so a steady trickle holds it and it ends
-- at most `grace` after the last item arrived (a raid on the extractor, a cut line, a lost town). Bonuses
-- (balance.nation.rare.kinds, deep-economy.md §3.7): saltpetre +25 % productivity of explosives and munitions, quartz
-- +20 % circuits (all three kinds), tungsten +20 % steel (LuaRecipe.productivity_bonus of every rts-* recipe and the
-- smelters' steel recipe that makes one of the kind's items), diamonds +15 % mining productivity, rare earths +10 % lab
-- speed and lab productivity, gold +15 % tax income (treasury.tax_bonus). Uranium rounds (D3): while the capital's
-- network pays one uranium rounds magazine a minute per heavy walker, the heavies deal +30 % (their ammo category's
-- damage modifier). Force modifiers are applied as deltas
-- against storage.rare.applied[force] (the research bookkeeping of scripts/research.lua: other writers of the same
-- modifiers, research and the hard AI, are left alone); match teardown takes them all back.
--
-- State: storage.nations[force].rare = {bonus = {[kind] = {active, since, last_tick, arrived}}, stats} (contract key);
-- storage.rare = {applied = {[force] = {recipes = {[name] = x}, mining, lab_speed, lab_productivity, tax}},
-- buffers = {[unit_number] = {item, n}}, produced = {[force] = {[kind] = n}}}. Log lines "[rts] rare: ...".
-- Console: /rts-rare [force] [give <kind> <n>].
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local supply = require("scripts.supply")
local match = require("scripts.match")
local ages = require("scripts.ages")
local territory = require("scripts.territory")
local treasury = require("scripts.treasury")
local world = require("scripts.world")
local hud = require("scripts.hud")
local age3 = require("scripts.age3")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local RB = balance.nation.rare

local rare = {}

rare.EXTRACTOR = RB.extractor
rare.KIND = "rare-extractor"
rare.ORDER = RB.order
rare.PREFIX = "rts-rare-"

buildings.KIND_BY_NAME[rare.EXTRACTOR] = rare.KIND
territory.CLASS_BY_NAME[rare.EXTRACTOR] = "outpost" -- own or neutral land (deposits lie on mountain rims and city-states)
local P4 = hud.P4
if P4 then
  P4.ALERT_STYLE["rare-gained"] = {icons = {"item/rts-rare-gold", "utility/check_mark_green"}, color = "green"}
  P4.ALERT_STYLE["rare-lost"] = {icons = {"item/rts-rare-gold", "utility/warning_icon"}, color = "yellow"}
end

--- Kind of a rare item, resource or extractor target name ("rts-rare-gold" -> "gold"), or nil.
function rare.kind_of(name)
  if type(name) ~= "string" or string.sub(name, 1, #rare.PREFIX) ~= rare.PREFIX then return nil end
  local k = string.sub(name, #rare.PREFIX + 1)
  return RB.kinds[k] and k or nil
end

---------------------------------------------------------------------------
-- Recipes per kind (static prototype data, built on first use)
---------------------------------------------------------------------------
local recipe_cache
local function recipes_of(kind)
  if not recipe_cache then
    recipe_cache = {}
    local names = {}
    for name in pairs(prototypes.recipe) do
      if string.sub(name, 1, 4) == "rts-" or balance.smelting[name] then names[#names + 1] = name end
    end
    table.sort(names)
    for _, k in ipairs(rare.ORDER) do
      local want = {}
      for _, item in ipairs(RB.kinds[k].items or {}) do want[item] = true end
      local list = {}
      if next(want) then
        for _, name in ipairs(names) do
          for _, p in ipairs(prototypes.recipe[name].products) do
            if want[p.name] then
              list[#list + 1] = name
              break
            end
          end
        end
      end
      recipe_cache[k] = list
    end
  end
  return recipe_cache[kind] or {}
end
rare.recipes_of = recipes_of

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.rare
  if not s then
    s = {}
    storage.rare = s
  end
  s.applied = s.applied or {}
  s.buffers = s.buffers or {}
  s.produced = s.produced or {}
  return s
end

function rare.init() S() end

local function N(force_name, create)
  local nations = storage.nations
  local n = nations and nations[force_name]
  if not n then return nil end
  local r = n.rare
  if not r and create then
    r = {bonus = {}, stats = {arrived = 0, gained = 0, lost = 0}}
    n.rare = r
  end
  return r
end

local function nation_mode() return ages.is_nation() end

---------------------------------------------------------------------------
-- Bonuses: deltas against what this module applied
---------------------------------------------------------------------------
local function near(a, b) return math.abs(a - b) < 1e-9 end

--- Recompute and apply the bonus set of a force (idempotent); `clear` takes every bonus back (match teardown).
function rare.apply(force_name, clear)
  local force = game.forces[force_name]
  if not (force and force.valid) then return end
  local want = {recipes = {}, mining = 0, lab_speed = 0, lab_productivity = 0, tax = 0, ammo = {}}
  local r = not clear and N(force_name) or nil
  local U = RB.uranium_rounds
  if r and r.rounds_on and nation_mode() then want.ammo[U.category] = U.damage end
  if r and nation_mode() then
    for _, kind in ipairs(rare.ORDER) do
      local b = r.bonus[kind]
      if b and b.active then
        local K = RB.kinds[kind]
        if K.productivity then
          for _, name in ipairs(recipes_of(kind)) do
            want.recipes[name] = (want.recipes[name] or 0) + K.productivity
          end
        end
        want.mining = want.mining + (K.mining or 0)
        want.lab_speed = want.lab_speed + (K.lab_speed or 0)
        want.lab_productivity = want.lab_productivity + (K.lab_productivity or 0)
        want.tax = want.tax + (K.tax or 0)
      end
    end
  end
  local s = S()
  local a = s.applied[force_name]
  if not a then
    a = {recipes = {}, mining = 0, lab_speed = 0, lab_productivity = 0, tax = 0}
    s.applied[force_name] = a
  end
  a.ammo = a.ammo or {}
  for _, cat in ipairs({U.category}) do
    local old, new = a.ammo[cat] or 0, want.ammo[cat] or 0
    if not near(old, new) then
      force.set_ammo_damage_modifier(cat, force.get_ammo_damage_modifier(cat) - old + new)
      a.ammo[cat] = new > 0 and new or nil
    end
  end
  local recipes = force.recipes
  local names = {}
  for name in pairs(a.recipes) do names[name] = true end
  for name in pairs(want.recipes) do names[name] = true end
  local list = {}
  for name in pairs(names) do list[#list + 1] = name end
  table.sort(list)
  for _, name in ipairs(list) do
    local old, new = a.recipes[name] or 0, want.recipes[name] or 0
    if not near(old, new) then
      local rec = recipes[name]
      if rec then rec.productivity_bonus = rec.productivity_bonus - old + new end
      a.recipes[name] = new > 0 and new or nil
    end
  end
  if not near(a.mining, want.mining) then
    force.mining_drill_productivity_bonus = force.mining_drill_productivity_bonus - a.mining + want.mining
    a.mining = want.mining
  end
  if not near(a.lab_speed, want.lab_speed) then
    force.laboratory_speed_modifier = force.laboratory_speed_modifier - a.lab_speed + want.lab_speed
    a.lab_speed = want.lab_speed
  end
  if not near(a.lab_productivity, want.lab_productivity) then
    force.laboratory_productivity_bonus = force.laboratory_productivity_bonus - a.lab_productivity
      + want.lab_productivity
    a.lab_productivity = want.lab_productivity
  end
  a.tax = want.tax
end

--- Gold: the share added to the tax income (treasury.lua).
treasury.tax_bonus = function(force_name)
  local s = storage.rare
  local a = s and s.applied[force_name]
  return a and a.tax or 0
end

function rare.bonuses(force_name)
  local r = N(force_name)
  local out = {}
  for _, kind in ipairs(rare.ORDER) do
    local b = r and r.bonus[kind]
    out[kind] = {active = b ~= nil and b.active == true, since = b and b.since, last_tick = b and b.last_tick,
                 arrived = b and b.arrived or 0}
  end
  return out
end

---------------------------------------------------------------------------
-- The capital's network: arrivals
---------------------------------------------------------------------------
local function capital_network(force_name)
  local cap = ages.capital(force_name)
  local e = cap and cap.entity
  if e and e.valid then
    local net = e.logistic_network
    if net and net.valid then return net end
  end
  local surface = match.surface()
  if cap and surface then return surface.find_logistic_network_by_position(cap.position, force_name) end
  return nil
end
rare.capital_network = capital_network

local function set_active(force_name, r, kind, b, on)
  b.active = on
  b.since = game.tick
  local K = RB.kinds[kind]
  util.log("rare: %s %s bonus %s at tick %d (arrived %d)", force_name, kind, on and "ON" or "off", game.tick,
    b.arrived or 0)
  if on then
    r.stats.gained = r.stats.gained + 1
    supply.alert(force_name, "rare-gained", "rts-age3.alert-rare-gained", {{"rts-age3.rare-" .. kind},
      {"rts-age3.rare-bonus-" .. kind}})
  else
    r.stats.lost = r.stats.lost + 1
    supply.alert(force_name, "rare-lost", "rts-age3.alert-rare-lost", {{"rts-age3.rare-" .. kind}, RB.grace})
  end
  return K
end

-- Uranium rounds: the heavies' magazines from the capital's network (true when the bonus switched)
local function rounds_step(force_name, r, net)
  local U = RB.uranium_rounds
  local have = net and net.get_item_count(U.item) or 0
  if have == 0 and not r.rounds_on then return false end
  local heavies = units.count(force_name, U.kind)
  local on
  if heavies == 0 then
    on = have > 0
  else
    r.rounds_due = (r.rounds_due or 0) + heavies * U.per_unit_minute * RB.check_period / 3600
    local take = math.floor(r.rounds_due)
    if take > 0 then
      local got = have > 0 and net.remove_item({name = U.item, count = math.min(take, have)}) or 0
      r.rounds_used = (r.rounds_used or 0) + got
      on = got >= take
      r.rounds_due = on and (r.rounds_due - got) or 0 -- a shortfall is not owed later
    else
      on = have > 0 or r.rounds_on == true
    end
  end
  if on == (r.rounds_on == true) then return false end
  r.rounds_on = on or nil
  util.log("rare: %s uranium rounds %s (%d heavies, %d magazines used)", force_name, on and "ON" or "off", heavies,
    r.rounds_used or 0)
  return true
end

local function check_force(force_name, now)
  local net = capital_network(force_name)
  local r = N(force_name, net ~= nil)
  if not r then return end
  local changed = rounds_step(force_name, r, net)
  local grace = RB.grace * 60
  for _, kind in ipairs(rare.ORDER) do
    local item = rare.PREFIX .. kind
    local b = r.bonus[kind]
    local n = net and net.get_item_count(item) or 0
    if n > 0 then
      local got = net.remove_item({name = item, count = n})
      if got > 0 then
        if not b then
          b = {active = false, arrived = 0}
          r.bonus[kind] = b
        end
        b.last_tick, b.arrived = now, (b.arrived or 0) + got
        r.stats.arrived = r.stats.arrived + got
        if not b.active then
          set_active(force_name, r, kind, b, true)
          changed = true
        end
      end
    end
    if b and b.active and now - (b.last_tick or 0) > grace then
      set_active(force_name, r, kind, b, false)
      changed = true
    end
  end
  if changed then rare.apply(force_name) end
end

events.on_nth_tick(RB.check_period, function(e)
  if not nation_mode() then return end
  local m = storage.match
  if not (m and m.phase == "running") then return end
  for _, f in ipairs(match.forces()) do check_force(f, e.tick) end
end)

---------------------------------------------------------------------------
-- Extractors: the dropped item goes into the network
---------------------------------------------------------------------------
local function pickup(un, rec)
  local e = rec.entity
  local s = S()
  local buf = s.buffers[un]
  local net = production.network_for(e)
  if net and buf and buf.n > 0 then
    local put = net.insert({name = buf.item, count = buf.n})
    buf.n = buf.n - put
    if buf.n <= 0 then s.buffers[un] = nil end
  end
  local items = e.surface.find_entities_filtered({type = "item-entity", position = e.drop_position, radius = 0.6})
  for _, it in ipairs(items) do
    local stack = it.valid and it.stack
    if stack and stack.valid_for_read and rare.kind_of(stack.name) then
      local name, count = stack.name, stack.count
      local put = net and net.insert({name = name, count = count}) or 0
      local left = count - put
      if left > 0 then
        buf = s.buffers[un] or {item = name, n = 0}
        if buf.item == name and buf.n + left <= RB.buffer then
          buf.n = buf.n + left
          s.buffers[un] = buf
          left = 0
        end
      end
      if left <= 0 then
        it.destroy()
      elseif left < count then
        stack.count = left
      end
      local made = count - left
      if made > 0 then
        local kind = rare.kind_of(name)
        local pf = s.produced[rec.force] or {}
        s.produced[rec.force] = pf
        pf[kind] = (pf[kind] or 0) + made
        if production.on_flow then production.on_flow(rec, name, made, "made") end
        if rec.rare_state ~= (net and "flowing" or "buffer") then
          rec.rare_state = net and "flowing" or "buffer"
          util.log("rare: extractor #%d (%s, %s) at %s: %s", un, rec.force, kind, util.pos_str(e.position),
            net and "items go into its network" or "no logistic network: items wait in its buffer")
        end
      end
    end
  end
end

events.on_nth_tick(RB.pickup_period, function()
  if not (storage.buildings and nation_mode()) then return end
  for un, rec in buildings.all(rare.KIND) do
    if rec.entity.valid then pickup(un, rec) end
  end
end)

buildings.on_removed(function(un)
  local s = storage.rare
  if s then s.buffers[un] = nil end
end)

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
--- The world's rare deposits with the force's extractor on each (if any) and whether that kind flows to its capital.
function rare.deposits(force_name)
  local out = {}
  local r = N(force_name)
  local surface = match.surface()
  for _, site in ipairs(world.sites("rare") or {}) do
    local kind = site.rare or rare.kind_of(site.resource)
    local ext
    if surface and site.position then
      local list = surface.find_entities_filtered({name = rare.EXTRACTOR, position = site.position,
                                                   radius = (RB.deposit_radius or 8), force = force_name})
      ext = list[1]
    end
    local b = r and kind and r.bonus[kind]
    out[#out + 1] = {kind = kind, position = site.position, extractor = ext, flowing = b ~= nil and b.active == true,
                     last_tick = b and b.last_tick or nil}
  end
  return out
end

--- Ledger line: the rare bonuses of the nation ("Rare: [item] Saltpetre +25 % explosives (flowing) ...").
local function ledger_line(force_name)
  local r = N(force_name)
  if not r then return nil end
  local parts = {""}
  local now = game.tick
  for _, kind in ipairs(rare.ORDER) do
    local b = r.bonus[kind]
    if b then
      local text
      if b.active then
        text = {"rts-age3.ledger-rare-on", "[item=" .. rare.PREFIX .. kind .. "]", {"rts-age3.rare-bonus-" .. kind},
                math.max(0, math.ceil((RB.grace * 60 - (now - (b.last_tick or now))) / 60))}
      else
        text = {"rts-age3.ledger-rare-off", "[item=" .. rare.PREFIX .. kind .. "]", {"rts-age3.rare-bonus-" .. kind}}
      end
      if #parts > 1 then parts[#parts + 1] = "   " end
      parts[#parts + 1] = text
      if #parts >= 17 then break end
    end
  end
  if r.rounds_on then
    if #parts > 1 then parts[#parts + 1] = "   " end
    parts[#parts + 1] = {"rts-age3.ledger-rounds", "[item=" .. RB.uranium_rounds.item .. "]",
                         math.floor(RB.uranium_rounds.damage * 100 + 0.5)}
  end
  if #parts == 1 then return {"rts-age3.ledger-rare-none"} end
  return {"", {"rts-age3.ledger-rare"}, " ", parts}
end
age3.ledger_lines[#age3.ledger_lines + 1] = ledger_line
rare.ledger_line = ledger_line

---------------------------------------------------------------------------
-- Teardown, describe, console
---------------------------------------------------------------------------
match.on_teardown(function()
  local s = storage.rare
  -- take every applied modifier back
  for force_name in pairs(s and s.applied or {}) do rare.apply(force_name, true) end
  for _, n in pairs(storage.nations or {}) do n.rare = nil end
  storage.rare = nil
  S()
end)

function rare.describe(force_name)
  local r = N(force_name)
  local parts = {}
  for _, kind in ipairs(rare.ORDER) do
    local b = r and r.bonus[kind]
    if b then parts[#parts + 1] = string.format("%s %s (%d)", kind, b.active and "on" or "off", b.arrived or 0) end
  end
  local a = storage.rare and storage.rare.applied[force_name]
  local ext = 0
  for _, rec in buildings.for_force(force_name, rare.KIND) do
    if rec.entity.valid then ext = ext + 1 end
  end
  return string.format("%s: rare [%s], extractors %d, mining +%.2f, lab speed +%.2f, tax +%.2f", force_name,
    table.concat(parts, ", "), ext, a and a.mining or 0, a and a.lab_speed or 0, a and a.tax or 0)
end

commands.add_command("rts-rare", "[force] [give <kind> <n>] - rare bonuses (QA: give puts items into the capital network)",
  function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    local words = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do words[#words + 1] = w end
    local f = (words[1] and game.forces[words[1]]) and table.remove(words, 1)
      or (player and player.force.name) or util.PLAYER_FORCE
    if words[1] == "give" and RB.kinds[words[2] or ""] then
      if player and not player.admin then
        player.print("rts-rare: admins only")
        return
      end
      local net = capital_network(f)
      if net then net.insert({name = rare.PREFIX .. words[2], count = tonumber(words[3]) or 1}) end
    end
    local line = rare.describe(f)
    if player then player.print(line) else log("[rts] " .. line) end
  end)

deps.rare = rare
return rare
