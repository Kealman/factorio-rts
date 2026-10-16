-- Abilities (docs/PHASE4.md section 1 "Micro and abilities"): five scripted abilities with per-force cooldowns.
--
--   stim       Z  Selected units: units below full health are healed by 30 % of their max health for 10 iron each
--                 from the CC networks (most damaged first, as many as the iron pays for). Drones and the Commander
--                 also get rts-stim-sticker: +50 % speed for 8 s. Spider-units (walker, heavy, raider, artillery) cannot
--                 be sped up: LuaEntity.speed is writable only for units, cars and projectiles, and stickers attach only
--                 to units, characters, cars and spider-vehicles (2.0.77 docs). Cooldown 30 s.
--   shield     C  The Commander and every own unit within 8 tiles of it: for 10 s an on_entity_damaged handler heals
--                 back 50 % of each hit (a killing blow is not reduced, as with Armor II/III). Needs a live Commander.
--                 Cooldown 45 s.
--   scanner    V  Targeted, needs rts-scanner. The next right click charts a 48x48 area for the force and keeps it
--                 visible for 30 s (force.chart again every RECHART ticks; a chart stays visible ~600 ticks, fog.lua),
--                 then the area falls back to the last chart like any other fogged area. Cooldown 60 s.
--   artillery  G  Targeted, needs an artillery walker. The next right click makes every own artillery walker whose
--                 range covers the point (8-44 tiles, the walker's own range) fire a volley of SHELLS rts-artillery-shell projectiles at it
--                 (scattered within 2 tiles); those that orders.lua may command then get orders.attack on the enemy
--                 nearest the point (attack_area radius 4 there, renewed while it lives). No artillery in range: the
--                 click is used up, nothing fires and no cooldown starts. Cooldown 20 s.
--   overcharge    Button only, needs rts-overcharge. For 10 s every rts turret prototype deals x2: the force's turret
--                 attack modifier m gets the delta 1 + m ((1 + m + delta) = 2 (1 + m)), and the same delta is taken
--                 off again at the end (research.lua applies its own deltas, so both coexist). Meanwhile the main CC's
--                 buffer loses 1 MW (1 MJ per second, 10 MJ in all, of its 200 MJ). Needs a CC. Cooldown 90 s.
--
-- Use: abilities.activate(player_index, name) is the hotkey and button path. Instant abilities cast at once; a
-- targeted one is armed (the same key again, X, or arming attack-move with F cancels it) and the next right click
-- casts it: the orders.on_right_click hook is registered first, so it beats the hauler and Commander hooks and the
-- normal orders. abilities.cast(player_index, name, position) runs one directly (the probe). The player index may be
-- the autotest's fake index 0 (force rts-player). Cooldowns belong to the force; a new match clears them.
-- Every use logs "[rts] ability <name> player=<i> force=<f> ...", a refusal "[rts] ability <name> refused ...".
--
-- Owns storage.abilities = {
--   match_id, cooldowns = {[force] = {[name] = ready tick}}, armed = {[player_index] = {name, tick}},
--   shielded = {[unit_number] = expiry tick}, scans = {{force, surface, area, center, until, next}},
--   overcharge = {[force] = {until, deltas = {[turret] = delta}, cc, drained}}, stats = {[name] = {used, refused}},
--   absorbed = shield damage healed back in total,
-- }
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local economy = require("scripts.economy")
local match = require("scripts.match")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local commander = require("scripts.commander")
local research = require("scripts.research")
local balance = require("balance")
local diplomacy = require("scripts.diplomacy") -- Phase 5 M2 diplomacy: targets must be hostile

local abilities = {}

abilities.LIST = {"stim", "shield", "scanner", "artillery", "overcharge"}
abilities.DEF = {
  stim = {input = "rts-ability-1", key = "Z", cooldown = 30 * 60, heal = 0.3, cost_item = "iron-plate", cost = 10,
          sticker = "rts-stim-sticker", sprite = "item/exoskeleton-equipment"},
  shield = {input = "rts-ability-2", key = "C", cooldown = 45 * 60, radius = 8, duration = 10 * 60, absorb = 0.5,
            sprite = "item/energy-shield-equipment"},
  scanner = {input = "rts-ability-3", key = "V", cooldown = 60 * 60, tech = "rts-scanner", targeted = true, size = 48,
             duration = 30 * 60, sprite = "item/radar"},
  artillery = {input = "rts-ability-4", key = "G", cooldown = 20 * 60, targeted = true, kind = "artillery",
               -- the artillery walker's own range and minimum range (balance.lua: 44 and 8; Wave C, was 40)
               range = balance.units["rts-artillery"].range, min_range = balance.units["rts-artillery"].min_range,
               shells = 2, scatter = 2, target_radius = 4,
               shell = "rts-artillery-shell", sprite = "item/artillery-targeting-remote"},
  overcharge = {cooldown = 90 * 60, tech = "rts-overcharge", duration = 10 * 60, factor = 2, drain = 1e6,
                sprite = "item/discharge-defense-equipment"},
}
abilities.TICK = 10            -- expiry checks, scanner re-charts, overcharge drain
abilities.PEACE_MARGIN = 4     -- Phase 5 M2 diplomacy: tiles beyond the strike radius kept clear of nations at peace
abilities.RECHART = 240        -- ticks between scanner re-charts
abilities.CHART_VISIBLE = 600  -- ticks a chart stays visible (fog.lua)
-- Kinds Stim works on (not haulers).
local STIM_KINDS = {walker = true, heavy = true, drone = true, raider = true, artillery = true, commander = true}
local STICKER_TYPES = {unit = true, ["spider-vehicle"] = true, car = true, character = true}
local COLORS = {
  stim = {r = 0.2, g = 1, b = 0.3, a = 0.8},
  shield = {r = 0.3, g = 0.65, b = 1, a = 0.8},
  scanner = {r = 0.3, g = 0.9, b = 1, a = 0.9},
  artillery = {r = 1, g = 0.45, b = 0.1, a = 1},
  overcharge = {r = 1, g = 0.9, b = 0.2, a = 0.9},
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function astate()
  local S = storage.abilities
  if not S then
    S = {}
    storage.abilities = S
  end
  S.cooldowns = S.cooldowns or {}
  S.armed = S.armed or {}
  S.shielded = S.shielded or {}
  S.scans = S.scans or {}
  S.overcharge = S.overcharge or {}
  S.stats = S.stats or {}
  S.absorbed = S.absorbed or 0
  return S
end

function abilities.init()
  astate()
end

local function stat(name, field)
  local st = astate().stats
  st[name] = st[name] or {used = 0, refused = 0}
  st[name][field] = st[name][field] + 1
end

--- Counters {[name] = {used, refused}}, and the shield's total healed-back damage.
function abilities.stats()
  local S = astate()
  return S.stats, S.absorbed
end

-- A new match clears cooldowns and armed abilities (forces persist across matches in one save).
local function sync_match()
  local S = astate()
  local m = storage.match
  local id = m and m.match_id
  if S.match_id ~= id then
    S.match_id = id
    S.cooldowns = {}
    S.armed = {}
    S.shielded = {}
    S.scans = {}
  end
  return S
end

local function cooldowns(force_name)
  local S = sync_match()
  local c = S.cooldowns[force_name]
  if not c then
    c = {}
    S.cooldowns[force_name] = c
  end
  return c
end

--- Ticks until the ability is ready again for the force (0 = ready).
function abilities.cooldown_left(force_name, name)
  local ready = cooldowns(force_name)[name]
  return ready and math.max(0, ready - game.tick) or 0
end

local function start_cooldown(force_name, name)
  cooldowns(force_name)[name] = game.tick + abilities.DEF[name].cooldown
end

--- Clear a force's cooldowns (probe, QA).
function abilities.reset_cooldowns(force_name)
  sync_match().cooldowns[force_name] = {}
end

---------------------------------------------------------------------------
-- Availability
---------------------------------------------------------------------------
local function selected_units(player_index, kinds)
  local out = {}
  for _, e in pairs(selection.get(player_index)) do
    local rec = storage.units[e.unit_number]
    if rec and (not kinds or kinds[rec.kind]) then out[#out + 1] = e end
  end
  return out
end

local function overcharge_active(force_name)
  local o = storage.abilities and storage.abilities.overcharge
  return o ~= nil and o[force_name] ~= nil
end

local function has_artillery(force_name)
  for _, rec in units.for_force(force_name) do
    if rec.kind == abilities.DEF.artillery.kind then return true end
  end
  return false
end

--- Whether the player's force can use the ability now: true, or false and a reason as a localised string. The checks
--- are those that do not need a target (a targeted ability can still be refused at the click).
function abilities.available(player_index, name)
  local def = abilities.DEF[name]
  if not def then return false, {"rts.ability-reason-unknown"} end
  local m = storage.match
  if not (m and m.surface and m.phase == "running") then return false, {"rts.ability-reason-no-match"} end
  local force_name = selection.force_name(player_index)
  if def.tech and not research.has(force_name, def.tech) then
    return false, {"rts.ability-reason-locked", {"technology-name." .. def.tech}}
  end
  local left = abilities.cooldown_left(force_name, name)
  if left > 0 then return false, {"rts.ability-reason-cooldown", math.ceil(left / 60)}, "cooldown" end
  if name == "stim" then
    if #selected_units(player_index, STIM_KINDS) == 0 then return false, {"rts.ability-reason-no-selection"} end
  elseif name == "shield" then
    if not commander.entity(force_name) then return false, {"rts.ability-reason-no-commander"} end
  elseif name == "artillery" then
    if not has_artillery(force_name) then return false, {"rts.ability-reason-no-artillery"} end
  elseif name == "overcharge" then
    if overcharge_active(force_name) then return false, {"rts.ability-reason-active"} end
    if not buildings.main_cc(force_name) then return false, {"rts.ability-reason-no-cc"} end
  end
  return true
end

--- The armed targeted ability of a player, or nil.
function abilities.armed(player_index)
  local a = astate().armed[player_index]
  return a and a.name or nil
end

local gui_hooks = {}
--- fn(player_index) after an ability was armed, disarmed or used (abilitygui.lua refreshes). Load time only.
function abilities.on_changed(fn) gui_hooks[#gui_hooks + 1] = fn end
local function changed(player_index)
  for i = 1, #gui_hooks do gui_hooks[i](player_index) end
end

local function message(player_index, text)
  local player = selection.real_player(player_index)
  if player then player.create_local_flying_text({text = text, create_at_cursor = true}) end
end

local function refuse(player_index, name, reason_key, reason, ...)
  stat(name, "refused")
  util.log("ability %s refused player=%d force=%s: %s", name, player_index, selection.force_name(player_index),
    select("#", ...) > 0 and string.format(reason, ...) or reason)
  message(player_index, reason_key)
  return false, reason_key
end

local function log_use(name, player_index, fmt, ...)
  stat(name, "used")
  util.log("ability %s player=%d force=%s %s", name, player_index, selection.force_name(player_index),
    string.format(fmt, ...))
end

---------------------------------------------------------------------------
-- Effects
---------------------------------------------------------------------------
local function ring(entity, color, ttl, force_name)
  local box = entity.selection_box
  local w, h = box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y
  rendering.draw_circle({color = color, radius = math.max(1, math.sqrt(w * w + h * h) / 2 + 0.3), width = 3,
    filled = false, target = entity, surface = entity.surface, time_to_live = ttl,
    forces = force_name and {force_name} or nil})
end

local function iron_available(force_name, item)
  local n = 0
  for _, net in ipairs(economy.networks(force_name)) do n = n + net.get_item_count(item) end
  return n
end

local function cast_stim(player_index, force_name)
  local def = abilities.DEF.stim
  local list = selected_units(player_index, STIM_KINDS)
  if #list == 0 then return refuse(player_index, "stim", {"rts.ability-reason-no-selection"}, "nothing selected") end
  local damaged, sticky = {}, {}
  for _, e in ipairs(list) do
    if e.health < e.max_health then damaged[#damaged + 1] = e end
    if STICKER_TYPES[e.type] then sticky[#sticky + 1] = e end
  end
  table.sort(damaged, function(a, b)
    local ra, rb = a.health / a.max_health, b.health / b.max_health
    if ra ~= rb then return ra < rb end
    return a.unit_number < b.unit_number
  end)
  local iron = iron_available(force_name, def.cost_item)
  local pay = math.min(#damaged, math.floor(iron / def.cost))
  if pay == 0 and #sticky == 0 then
    if #damaged == 0 then
      return refuse(player_index, "stim", {"rts.ability-reason-full-health"}, "%d units at full health", #list)
    end
    return refuse(player_index, "stim", {"rts.ability-reason-no-iron", def.cost}, "%d iron for %d damaged units", iron,
      #damaged)
  end
  local paid = pay > 0 and economy.take(force_name, def.cost_item, pay * def.cost) or 0
  pay = math.min(pay, math.floor(paid / def.cost))
  local healed = 0
  for i = 1, pay do
    local e = damaged[i]
    local before = e.health
    e.health = math.min(e.max_health, e.health + e.max_health * def.heal)
    healed = healed + (e.health - before)
    ring(e, COLORS.stim, 45)
  end
  local sped = 0
  for _, e in ipairs(sticky) do
    local s = e.surface.create_entity({name = def.sticker, position = e.position, target = e, force = e.force})
    if s then
      sped = sped + 1
      ring(e, COLORS.stim, 45)
    end
  end
  start_cooldown(force_name, "stim")
  log_use("stim", player_index, "selected=%d healed=%d (+%.0f hp) iron=%d of %d sped=%d", #list, pay, healed, paid,
    iron, sped)
  return true
end

local function cast_shield(player_index, force_name)
  local def = abilities.DEF.shield
  local c = commander.entity(force_name)
  if not c then return refuse(player_index, "shield", {"rts.ability-reason-no-commander"}, "no Commander") end
  local S = astate()
  local until_tick = game.tick + def.duration
  local n = 0
  for _, e in pairs(c.surface.find_entities_filtered({position = c.position, radius = def.radius, force = c.force,
                                                      type = {"spider-unit", "unit", "spider-vehicle"}})) do
    if e.unit_number and storage.units[e.unit_number] then
      S.shielded[e.unit_number] = until_tick
      ring(e, COLORS.shield, def.duration)
      n = n + 1
    end
  end
  rendering.draw_circle({color = {r = 0.3, g = 0.65, b = 1, a = 0.25}, radius = def.radius, width = 2, filled = false,
    target = c, surface = c.surface, time_to_live = 60})
  start_cooldown(force_name, "shield")
  log_use("shield", player_index, "commander=#%d units=%d radius=%d until=%d", c.unit_number, n, def.radius, until_tick)
  return true
end

local function chart_area(force, surface, area)
  force.chart(surface, area)
end

local function cast_scanner(player_index, force_name, position)
  local def = abilities.DEF.scanner
  local surface = match.surface()
  local force = game.forces[force_name]
  if not (surface and force) then return refuse(player_index, "scanner", {"rts.ability-reason-no-match"}, "no arena") end
  local x, y = util.xy(position)
  local h = def.size / 2
  local area = {{x - h, y - h}, {x + h, y + h}}
  chart_area(force, surface, area)
  local S = astate()
  S.scans[#S.scans + 1] = {force = force_name, surface = surface.index, area = area, center = {x = x, y = y},
                           until_tick = game.tick + def.duration, next = game.tick + abilities.RECHART, charts = 1}
  rendering.draw_rectangle({color = COLORS.scanner, width = 2, filled = false, left_top = area[1],
    right_bottom = area[2], surface = surface, time_to_live = def.duration, forces = {force_name}})
  start_cooldown(force_name, "scanner")
  log_use("scanner", player_index, "at %s area %dx%d for %ds", util.pos_str(position), def.size, def.size,
    def.duration / 60)
  return true
end

local function enemy_near(force, surface, position, radius)
  local best, best_d, best_unit
  for _, e in pairs(surface.find_entities_filtered({position = position, radius = radius})) do
    if e.valid and diplomacy.hostile(force.name, e.force.name) and e.is_entity_with_health -- Phase 5 M2 diplomacy
       and e.type ~= "spider-leg" then
      local is_unit = e.unit_number ~= nil and storage.units[e.unit_number] ~= nil
      local d = util.distance_sq(e, position)
      if not best or (is_unit and not best_unit) or (is_unit == best_unit and d < best_d) then
        best, best_d, best_unit = e, d, is_unit
      end
    end
  end
  return best
end

local function cast_artillery(player_index, force_name, position)
  local def = abilities.DEF.artillery
  local surface = match.surface()
  local force = game.forces[force_name]
  local x, y = util.xy(position)
  local guns, any = {}, false
  for _, rec in units.for_force(force_name) do
    if rec.kind == def.kind then
      any = true
      local d = util.distance(rec.entity, {x = x, y = y})
      if d <= def.range and d >= def.min_range and rec.entity.surface == surface then guns[#guns + 1] = rec end
    end
  end
  -- Phase 5 M2 diplomacy: the shells hit every force but the own ("not-same"), so a strike near a nation at peace (or an
  -- ally) is refused. Skirmish: every other force is at war, nothing to check.
  if diplomacy.nation() then
    local peaceful = {}
    for _, f in ipairs(diplomacy.nations()) do
      if f ~= force_name and not diplomacy.hostile(force_name, f) then peaceful[#peaceful + 1] = f end
    end
    if #peaceful > 0 and surface.count_entities_filtered({position = {x = x, y = y}, force = peaceful, limit = 1,
        radius = def.target_radius + def.scatter + abilities.PEACE_MARGIN}) > 0 then
      return refuse(player_index, "artillery", {"rts.ability-reason-not-at-war"}, "a nation at peace near %s",
        util.pos_str(position))
    end
  end
  if #guns == 0 then
    if not any then
      return refuse(player_index, "artillery", {"rts.ability-reason-no-artillery"}, "no artillery walker")
    end
    return refuse(player_index, "artillery", {"rts.ability-reason-out-of-range", def.range},
      "no artillery walker within %d-%d tiles of %s", def.min_range, def.range, util.pos_str(position))
  end
  local shells = 0
  for gi, rec in ipairs(guns) do
    local a = rec.entity
    for k = 1, def.shells do
      -- deterministic scatter: a small golden-angle spiral around the point
      local i = (gi - 1) * def.shells + k - 1
      local r, ang = def.scatter * math.sqrt(i / math.max(1, #guns * def.shells - 1)), i * 2.39996
      local target = {x = x + r * math.cos(ang), y = y + r * math.sin(ang)}
      local p = surface.create_entity({name = def.shell, position = a.position, target = target, source = a, cause = a,
                                       force = force, speed = 0.6, max_range = def.range + 10})
      if p then shells = shells + 1 end
    end
  end
  -- keep firing at the enemy nearest the point (units orders.lua may command)
  local enemy = enemy_near(force, surface, {x = x, y = y}, def.target_radius)
  local follow = 0
  if enemy then
    local list = {}
    for _, rec in ipairs(guns) do list[#list + 1] = rec.entity end
    follow = orders.attack(list, enemy)
  end
  rendering.draw_circle({color = COLORS.artillery, radius = def.target_radius, width = 3, filled = false,
    target = {x = x, y = y}, surface = surface, time_to_live = 120, forces = {force_name}})
  start_cooldown(force_name, "artillery")
  log_use("artillery", player_index, "at %s guns=%d shells=%d target=%s follow-up attack=%d", util.pos_str(position),
    #guns, shells, enemy and string.format("%s (%s)", enemy.name, enemy.force.name) or "none", follow)
  return true
end

local function turret_names()
  local list = research.turret_names and research.turret_names()
  if list and #list > 0 then return list end
  list = {}
  for name in pairs(prototypes.get_entity_filtered({{filter = "turret"}})) do
    if string.sub(name, 1, 4) == "rts-" then list[#list + 1] = name end
  end
  table.sort(list)
  return list
end

local function modifiers_line(force)
  local parts = {}
  for _, t in ipairs(turret_names()) do
    parts[#parts + 1] = string.format("%s=%.2f", t, force.get_turret_attack_modifier(t))
  end
  return table.concat(parts, " ")
end
abilities.modifiers_line = modifiers_line

local function cast_overcharge(player_index, force_name)
  local def = abilities.DEF.overcharge
  if overcharge_active(force_name) then
    return refuse(player_index, "overcharge", {"rts.ability-reason-active"}, "already active")
  end
  local cc = buildings.main_cc(force_name)
  if not cc then return refuse(player_index, "overcharge", {"rts.ability-reason-no-cc"}, "no CC") end
  local force = game.forces[force_name]
  local before = modifiers_line(force)
  local deltas = {}
  for _, t in ipairs(turret_names()) do
    local m = force.get_turret_attack_modifier(t)
    local d = (def.factor - 1) * (1 + m)
    force.set_turret_attack_modifier(t, m + d)
    deltas[t] = d
  end
  astate().overcharge[force_name] = {until_tick = game.tick + def.duration, deltas = deltas, cc = cc.entity,
                                     drained = 0, next_drain = game.tick}
  local n = 0
  local surface = match.surface()
  if surface then
    for _, e in pairs(surface.find_entities_filtered({force = force, name = turret_names()})) do
      ring(e, COLORS.overcharge, def.duration)
      n = n + 1
    end
  end
  start_cooldown(force_name, "overcharge")
  log_use("overcharge", player_index, "turrets=%d modifiers %s -> %s, cc buffer %.1f MJ, drain %.1f MW for %ds", n,
    before, modifiers_line(force), cc.entity.energy / 1e6, def.drain / 1e6, def.duration / 60)
  return true
end

local function end_overcharge(force_name, o)
  local force = game.forces[force_name]
  if force then
    for t, d in pairs(o.deltas) do force.set_turret_attack_modifier(t, force.get_turret_attack_modifier(t) - d) end
  end
  astate().overcharge[force_name] = nil
  util.log("ability overcharge ended force=%s modifiers %s, drained %.1f MJ", force_name,
    force and modifiers_line(force) or "-", o.drained / 1e6)
end

local CAST = {stim = cast_stim, shield = cast_shield, scanner = cast_scanner, artillery = cast_artillery,
              overcharge = cast_overcharge}

--- Run an ability for a player now (targeted ones need `position`). Checks availability first. Returns ok, reason.
function abilities.cast(player_index, name, position)
  local def = abilities.DEF[name]
  if not def then return false, "unknown ability" end
  local ok, reason = abilities.available(player_index, name)
  if not ok then
    stat(name, "refused")
    util.log("ability %s refused player=%d force=%s: %s", name, player_index, selection.force_name(player_index),
      type(reason) == "table" and tostring(reason[1]) or tostring(reason))
    message(player_index, reason)
    changed(player_index)
    return false, reason
  end
  if def.targeted and not position then return false, "no target" end
  local done, why = CAST[name](player_index, selection.force_name(player_index), position)
  changed(player_index)
  return done, why
end

--- Cancel a player's armed ability. Returns true when one was armed.
function abilities.disarm(player_index, why)
  local S = astate()
  local a = S.armed[player_index]
  if not a then return false end
  S.armed[player_index] = nil
  util.log("ability %s disarmed player=%d (%s)", a.name, player_index, why or "-")
  changed(player_index)
  return true
end

--- Hotkey and button path: cast an instant ability; arm (or, when armed, disarm) a targeted one.
function abilities.activate(player_index, name)
  local def = abilities.DEF[name]
  if not def then return false end
  local S = sync_match()
  if def.targeted then
    local a = S.armed[player_index]
    if a and a.name == name then return abilities.disarm(player_index, "pressed again") and false end
    local ok, reason = abilities.available(player_index, name)
    if not ok then
      stat(name, "refused")
      util.log("ability %s refused player=%d force=%s: %s", name, player_index, selection.force_name(player_index),
        type(reason) == "table" and tostring(reason[1]) or tostring(reason))
      message(player_index, reason)
      changed(player_index)
      return false, reason
    end
    if orders.is_armed(player_index) then orders.arm_attack_move(player_index, false) end
    S.armed[player_index] = {name = name, tick = game.tick}
    util.log("ability %s armed player=%d: next right click", name, player_index)
    message(player_index, {"rts.ability-armed", {"rts.ability-" .. name}})
    changed(player_index)
    return true
  end
  abilities.disarm(player_index, "another ability")
  return abilities.cast(player_index, name)
end

-- The armed ability takes the next right click (registered first: before the hauler and Commander hooks).
orders.on_right_click(function(player_index, position, entities, alt)
  local S = storage.abilities
  local a = S and S.armed and S.armed[player_index]
  if not a then return nil end
  S.armed[player_index] = nil
  local ok = abilities.cast(player_index, a.name, position)
  return "ability-" .. a.name, ok and 1 or 0
end, true)

---------------------------------------------------------------------------
-- Shield: heal back a share of each hit (the shared on_entity_damaged filter, see below)
---------------------------------------------------------------------------
--- on_entity_damaged handler (exposed for the probe).
function abilities.on_damaged(e)
  local S = storage.abilities
  local sh = S and S.shielded
  if not sh or next(sh) == nil then return end
  local entity = e.entity
  if not (entity and entity.valid) then return end
  local un = entity.unit_number
  local until_tick = un and sh[un]
  if not until_tick then return end
  if game.tick > until_tick then
    sh[un] = nil
    return
  end
  if e.final_health <= 0 then return end
  local heal = e.final_damage_amount * abilities.DEF.shield.absorb
  if heal <= 0 then return end
  entity.health = entity.health + heal
  S.absorbed = S.absorbed + heal
end

events.on(defines.events.on_entity_damaged, abilities.on_damaged)
do
  -- One filter per event per mod (docs/qa/phase4-research-notes.md "The damage filter"): keep the filter that
  -- scripts/research.lua set (buildings and armored units) and add the Commander, which is a spider-vehicle and not in
  -- it. Set at load, after research.lua (control.lua order), identically on every load.
  local filters = script.get_event_filter(defines.events.on_entity_damaged)
  if filters then
    local have = false
    for _, f in ipairs(filters) do
      if f.filter == "name" and f.name == commander.NAME then have = true end
    end
    if not have and prototypes.entity[commander.NAME] then
      local out = {}
      for i, f in ipairs(filters) do out[i] = f end
      out[#out + 1] = {filter = "name", name = commander.NAME}
      script.set_event_filter(defines.events.on_entity_damaged, out)
    end
  end
end

---------------------------------------------------------------------------
-- Ticking state: shield expiry, scanner re-charts, overcharge drain and end
---------------------------------------------------------------------------
events.on_nth_tick(abilities.TICK, function(e)
  local S = storage.abilities
  if not S then return end
  local tick = e.tick
  if S.shielded and next(S.shielded) then
    for un, t in pairs(S.shielded) do
      if tick > t then S.shielded[un] = nil end
    end
  end
  if S.scans and #S.scans > 0 then
    local keep = {}
    for _, sc in ipairs(S.scans) do
      if tick < sc.until_tick then
        if tick >= sc.next and tick + abilities.CHART_VISIBLE <= sc.until_tick then
          local force, surface = game.forces[sc.force], game.surfaces[sc.surface]
          if force and surface then
            chart_area(force, surface, sc.area)
            sc.charts = sc.charts + 1
          end
          sc.next = tick + abilities.RECHART
        end
        keep[#keep + 1] = sc
      else
        util.log("ability scanner ended force=%s at %s after %d charts", sc.force, util.pos_str(sc.center), sc.charts)
      end
    end
    S.scans = keep
  end
  if S.overcharge and next(S.overcharge) then
    for force_name, o in pairs(S.overcharge) do
      if tick >= o.until_tick then
        end_overcharge(force_name, o)
      elseif tick >= o.next_drain then
        o.next_drain = tick + 60
        local cc = o.cc
        if cc and cc.valid then
          local take = math.min(cc.energy, abilities.DEF.overcharge.drain)
          cc.energy = cc.energy - take
          o.drained = o.drained + take
        end
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Inputs
---------------------------------------------------------------------------
for _, name in ipairs(abilities.LIST) do
  local def = abilities.DEF[name]
  if def.input then events.on(def.input, function(e) abilities.activate(e.player_index, name) end) end
end

-- X (stop) cancels an armed ability; F arms attack-move (orders.lua's handler runs first), which replaces it.
events.on("rts-stop", function(e) abilities.disarm(e.player_index, "stop") end)
events.on("rts-attack-move", function(e)
  if orders.is_armed(e.player_index) then abilities.disarm(e.player_index, "attack-move armed") end
end)

return abilities
