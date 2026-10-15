-- Research (docs/PHASE4.md sections 1 and 4; docs/qa/phase4-research-notes.md): labs, the RTS technologies, their
-- effects, unit unlocks, mk2 switching and the barracks kit gate.
--
-- Technologies are defined in prototypes/research.lua (cost, tier, prerequisites) without engine effects. Every effect
-- is applied here from the set of researched rts-* technologies (research.apply), as a delta against what this module
-- applied before, so other writers of the same force modifiers (the hard AI's mining bonus) are left alone and a new
-- match can reset research by un-researching.
--
-- Forces: every force named rts-* is initialised once (research.init_force): vanilla technologies are disabled, the
-- rts-* ones enabled. A new match (storage.match.match_id changed) resets every rts-* force: queue cleared, rts-*
-- technologies un-researched, effects removed. Both happen lazily (on_force_created, a 60-tick sweep, and at the top
-- of every API entry point), because match.lua is not ours to edit.
--
-- Labs (rts-lab, buildings kind "lab", registered by adding it to buildings.KIND_BY_NAME at load time) take the
-- current research's kits from the logistic network they stand in, every LAB_PERIOD ticks.
--
-- Barracks gate (production.kit_gate, called by production.lua before a kit becomes a unit):
--   1. a unit locked by research (LOCKS) is refused: the kit stays in the output, rec.research_block says why;
--      forces run by an AI commander are exempt while AI_IGNORES_LOCKS is true (the AI does not research yet);
--   2. after Armor I the unit is replaced by its mk2 prototype (balance.units[mk2].base = unit) when MK2_AUTO is on;
--      the mk2 kit recipes start disabled (prototypes/recipes.lua) and stay so: tier-1 kits deploy mk2 units;
--   3. supply.can_spawn must allow it (scripts/supply.lua), else the kit waits and an alert is raised.
--
-- Recipes: a recipe named in an unlock list whose prototype starts disabled (laser turret, steam plant) is enabled
-- per force when the technology is researched (and disabled again by a reset). Tier-1 kit recipes stay enabled.
--
-- Armor II/III: an on_entity_damaged handler heals back ARMOR share of the damage taken by ARMORED units of a force
-- with those technologies. The event filter is shared with scripts/ai/init.lua, whose handler treats every damaged
-- entity of an AI force as a base threat, so ARMORED is the mk2 unit names only (only researching forces have mk2
-- units) unless ARMOR_ALL_UNITS is switched on after that handler ignores units.
--
-- Owns storage.research:
--   version, match_id (match the forces were last reset for)
--   forces[force]        = true once init_force ran
--   applied[force]       = {ammo = {[category] = x}, turret = {[name] = x}, mining = x, robot_speed = x,
--                           robot_storage = x}  modifiers this module added (removed again by deltas)
--   unlocked[force]      = {[unit / kit / building / recipe name] = true}   read by the HUD build menu
--   flags[force]         = {steam = true, overcharge = true, scanner = true}   read by the abilities agent
--   supply_bonus[force]  = n         read by supply.cap
--   hauler_slots[force]  = n         extra hauler cargo slots, read by the logistics agent
--   hub_robots[force]    = n         extra robots per hub (Logistics I), read by the logistics agent
--   armor[force]         = 0..1      damage share healed back (Armor II/III)
--   mk2[force]           = true      Armor I researched: barracks deploy mk2 units
--   blocked[force]       = {reason, tech?, unit, tick, used?, cap?}   last refused kit of the force
--   stats                = {heals, healed, reverse_tick}
-- and these fields of storage.buildings records: rec.research_block (barracks, same shape as blocked[force]),
-- rec.lab_state (labs: "idle" | "researching" | "starved: <kit>" | "no network").
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local supply = require("scripts.supply")

local balance
do
  local ok, mod = pcall(require, "balance")
  if ok and type(mod) == "table" then balance = mod end
end

local research = {}

research.PREFIX = "rts-"
research.LAB = "rts-lab"
research.KITS = {"rts-science-basic", "rts-science-advanced"}
research.LAB_PERIOD = 60
research.LAB_MIN = 2          -- refill a lab holding fewer kits of an ingredient than this
research.LAB_FEED = 5         -- ... up to this many
research.SYNC_PERIOD = 60
research.ATTACK_STEP = 0.15   -- per attack level: ammo damage of the units' categories and turret attack
research.AI_IGNORES_LOCKS = true
research.MK2_AUTO = true      -- Armor I: tier-1 kits deploy mk2 units
research.ARMOR_ALL_UNITS = false
research.LOCK_ALERT_PERIOD = 30 * 60

-- The lab is a building of kind "lab" (scripts/buildings.lua registers by this table on every build event).
buildings.KIND_BY_NAME[research.LAB] = "lab"

-- Effects per technology. Levels add up: attack levels, armor shares, mining, supply.
research.EFFECTS = {
  ["rts-attack-1"] = {attack = 1},
  ["rts-attack-2"] = {attack = 1},
  ["rts-attack-3"] = {attack = 1},
  ["rts-armor-1"] = {mk2 = true},
  ["rts-armor-2"] = {armor = 0.10},
  ["rts-armor-3"] = {armor = 0.10},
  ["rts-mining-1"] = {mining = 0.25},
  ["rts-mining-2"] = {mining = 0.25},
  ["rts-logistics-1"] = {robot_speed = 0.5, robot_storage = 1, hub_robots = 5},
  ["rts-supply-1"] = {supply = 10},
  ["rts-supply-2"] = {supply = 10},
  ["rts-hauler-capacity-1"] = {hauler_slots = 10},
  ["rts-unlock-heavy"] = {unlock = {"rts-walker-heavy", "rts-walker-heavy-kit"}},
  ["rts-unlock-raider"] = {unlock = {"rts-raider", "rts-raider-kit"}},
  ["rts-unlock-artillery"] = {unlock = {"rts-artillery", "rts-artillery-kit"}},
  ["rts-unlock-laser"] = {unlock = {"rts-laser-turret"}},
  ["rts-steam-power"] = {unlock = {"rts-steam-plant"}, flag = "steam"},
  ["rts-overcharge"] = {flag = "overcharge"},
  ["rts-scanner"] = {flag = "scanner"},
}

-- name -> technology that unlocks it
research.LOCKS = {}
for tech, eff in pairs(research.EFFECTS) do
  for _, name in ipairs(eff.unlock or {}) do research.LOCKS[name] = tech end
end

local function is_rts_name(name) return string.sub(name, 1, #research.PREFIX) == research.PREFIX end

local function is_rts_force(force)
  return force and force.valid and is_rts_name(force.name)
end

---------------------------------------------------------------------------
-- Prototype-derived tables (static data: identical on every client)
---------------------------------------------------------------------------
local derived

local function derive()
  if derived then return derived end
  derived = {techs = {}, unit_categories = {}, turrets = {}, mk2 = {}, units = {}, armored = {}, locked_recipes = {}}
  -- technologies, in prototype order (tier 1 first)
  for name, proto in pairs(prototypes.technology) do
    if is_rts_name(name) then
      local ing = proto.research_unit_ingredients[1]
      derived.techs[#derived.techs + 1] = {
        name = name,
        order = proto.order,
        count = proto.research_unit_count,
        kit = ing and ing.name,
        tier = (ing and ing.name == "rts-science-advanced") and 2 or 1,
        prerequisites = proto.prerequisites,
      }
    end
  end
  table.sort(derived.techs, function(a, b) return a.order < b.order end)
  -- our units and their ammo categories; turrets
  local cats = {}
  for name, proto in pairs(prototypes.get_entity_filtered({{filter = "type", type = "spider-unit"},
                                                           {filter = "type", type = "unit"}})) do
    if is_rts_name(name) then
      derived.units[#derived.units + 1] = name
      local ap = proto.attack_parameters
      for _, cat in ipairs(ap and ap.ammo_categories or {}) do cats[cat] = true end
    end
  end
  table.sort(derived.units)
  -- balance.lua's per-role categories too (the commander is a spider-vehicle, not in the filter above)
  for _, u in pairs(balance and balance.units or {}) do
    if u.ammo_category and prototypes.ammo_category[u.ammo_category] then cats[u.ammo_category] = true end
  end
  for cat in pairs(cats) do derived.unit_categories[#derived.unit_categories + 1] = cat end
  table.sort(derived.unit_categories)
  for name in pairs(prototypes.get_entity_filtered({{filter = "turret"}})) do
    if is_rts_name(name) then derived.turrets[#derived.turrets + 1] = name end
  end
  table.sort(derived.turrets)
  for _, name in ipairs(derived.units) do
    local b = balance and balance.units and balance.units[name]
    local base = b and b.base or string.match(name, "^(.*)%-mk2$")
    if base and prototypes.entity[base] then derived.mk2[base] = name end
  end
  for _, name in ipairs(derived.units) do
    if research.ARMOR_ALL_UNITS or string.match(name, "%-mk2$") then derived.armored[name] = true end
  end
  -- recipes that research unlocks: those whose prototype starts disabled (tier-1 kits stay enabled: the barracks
  -- gate refuses them instead)
  for name in pairs(research.LOCKS) do
    local r = prototypes.recipe[name]
    if r and not r.enabled then derived.locked_recipes[#derived.locked_recipes + 1] = name end
  end
  table.sort(derived.locked_recipes)
  return derived
end

--- Ordered list of {name, order, count, kit, tier, prerequisites} for every rts-* technology.
function research.list() return derive().techs end

--- The mk2 prototype name of a unit, or nil.
function research.mk2_of(unit_name) return derive().mk2[unit_name] end

--- Ammo categories of our units (attack upgrades apply to these) and our turret names.
function research.unit_ammo_categories() return derive().unit_categories end
function research.turret_names() return derive().turrets end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function R() return storage.research end

function research.init()
  local r = storage.research or {}
  storage.research = r
  r.version = 1
  for _, key in ipairs({"forces", "applied", "unlocked", "flags", "supply_bonus", "hauler_slots", "hub_robots",
                        "armor", "mk2", "blocked"}) do
    r[key] = r[key] or {}
  end
  r.stats = r.stats or {heals = 0, healed = 0}
end

-- Sum of the effects of the researched rts-* technologies of a force.
local function compute(force)
  local t = {attack = 0, armor = 0, mining = 0, robot_speed = 0, robot_storage = 0, hub_robots = 0, supply = 0,
             hauler_slots = 0, mk2 = false, unlocked = {}, flags = {}, techs = {}}
  local techs = force.technologies
  for name, eff in pairs(research.EFFECTS) do
    local tech = techs[name]
    if tech and tech.researched then
      t.techs[#t.techs + 1] = name
      for _, key in ipairs({"attack", "armor", "mining", "robot_speed", "robot_storage", "hub_robots", "supply",
                            "hauler_slots"}) do
        if eff[key] then t[key] = t[key] + eff[key] end
      end
      if eff.mk2 then t.mk2 = true end
      if eff.flag then t.flags[eff.flag] = true end
      for _, n in ipairs(eff.unlock or {}) do t.unlocked[n] = true end
    end
  end
  table.sort(t.techs)
  return t
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

--- Recompute and apply every research effect of a force (idempotent). Returns the computed table.
function research.apply(force)
  local r = R()
  local name = force.name
  local t = compute(force)
  local a = r.applied[name]
  if not a then
    a = {ammo = {}, turret = {}, mining = 0, robot_speed = 0, robot_storage = 0}
    r.applied[name] = a
  end
  local d = derive()
  local dmg = t.attack * research.ATTACK_STEP
  for _, cat in ipairs(d.unit_categories) do
    local old = a.ammo[cat] or 0
    if not near(old, dmg) then
      force.set_ammo_damage_modifier(cat, force.get_ammo_damage_modifier(cat) - old + dmg)
      a.ammo[cat] = dmg
    end
  end
  for _, turret in ipairs(d.turrets) do
    local old = a.turret[turret] or 0
    if not near(old, dmg) then
      force.set_turret_attack_modifier(turret, force.get_turret_attack_modifier(turret) - old + dmg)
      a.turret[turret] = dmg
    end
  end
  if not near(a.mining, t.mining) then
    force.mining_drill_productivity_bonus = force.mining_drill_productivity_bonus - a.mining + t.mining
    a.mining = t.mining
  end
  if not near(a.robot_speed, t.robot_speed) then
    force.worker_robots_speed_modifier = force.worker_robots_speed_modifier - a.robot_speed + t.robot_speed
    a.robot_speed = t.robot_speed
  end
  if not near(a.robot_storage, t.robot_storage) then
    force.worker_robots_storage_bonus = force.worker_robots_storage_bonus - a.robot_storage + t.robot_storage
    a.robot_storage = t.robot_storage
  end
  r.unlocked[name] = t.unlocked
  r.flags[name] = t.flags
  r.supply_bonus[name] = t.supply > 0 and t.supply or nil
  r.hauler_slots[name] = t.hauler_slots > 0 and t.hauler_slots or nil
  r.hub_robots[name] = t.hub_robots > 0 and t.hub_robots or nil
  r.armor[name] = t.armor > 0 and t.armor or nil
  r.mk2[name] = t.mk2 or nil
  for _, recipe_name in ipairs(d.locked_recipes) do
    local recipe = force.recipes[recipe_name]
    local want = t.unlocked[recipe_name] == true
    if recipe and recipe.enabled ~= want then recipe.enabled = want end
  end
  return t
end

--- Disable the vanilla technologies of an rts-* force, enable ours, apply effects. Idempotent.
function research.init_force(force)
  if type(force) == "string" then force = game.forces[force] end
  if not is_rts_force(force) then return false end
  local disabled = 0
  for name, tech in pairs(force.technologies) do
    if is_rts_name(name) then
      if not tech.enabled then tech.enabled = true end
    elseif tech.enabled then
      tech.enabled = false
      disabled = disabled + 1
    end
  end
  -- a vanilla technology left in the queue (forces made before this module) would block it
  local queue = force.research_queue or {}
  for _, tech in ipairs(queue) do
    if not is_rts_name(tech.name) then
      force.research_queue = {}
      break
    end
  end
  R().forces[force.name] = true
  research.apply(force)
  util.log("research: force %s initialised: %d vanilla technologies disabled, %d rts technologies, unit ammo "
    .. "categories [%s], turrets [%s], mk2 units %d", force.name, disabled, #research.list(),
    table.concat(derive().unit_categories, " "), table.concat(derive().turrets, " "), table_size(derive().mk2))
  return true
end

--- Un-research every rts-* technology of the force, empty its queue, remove the effects (new match).
function research.reset_force(force)
  if type(force) == "string" then force = game.forces[force] end
  if not is_rts_force(force) then return false end
  local r = R()
  if not r.forces[force.name] then research.init_force(force) end
  force.research_queue = {}
  local list = research.list()
  local undone = 0
  r.resetting = true
  for i = #list, 1, -1 do -- successors first
    local tech = force.technologies[list[i].name]
    if tech then
      if tech.researched then
        tech.researched = false
        undone = undone + 1
      end
      if tech.saved_progress > 0 then tech.saved_progress = 0 end
    end
  end
  r.resetting = nil
  r.blocked[force.name] = nil
  research.apply(force)
  util.log("research: force %s reset for match %s: %d technologies un-researched", force.name, tostring(r.match_id),
    undone)
  return true
end

--- Bring storage.research in line with the current match: new match -> reset every rts-* force; uninitialised
--- rts-* forces -> init. Cheap when nothing changed. Every API entry point calls it.
function research.sync()
  local r = R()
  if not r then return end
  local m = storage.match
  local id = m and m.match_id or 0
  if r.match_id ~= id then
    r.match_id = id
    for _, force in pairs(game.forces) do
      if is_rts_force(force) then research.reset_force(force) end
    end
  end
end

local function ensure(force_name)
  research.sync()
  local r = R()
  if not r.forces[force_name] and game.forces[force_name] then research.init_force(game.forces[force_name]) end
end

---------------------------------------------------------------------------
-- Queries (HUD, AI, logistics, abilities)
---------------------------------------------------------------------------
--- True unless `name` (unit, kit, building or recipe) is locked by a technology the force has not researched.
function research.is_unlocked(force_name, name)
  if not research.LOCKS[name] then return true end
  local u = R().unlocked[force_name]
  return u ~= nil and u[name] == true
end

--- Technology that unlocks `name`, or nil.
function research.lock_of(name) return research.LOCKS[name] end

--- True when the force has researched the technology.
function research.has(force_name, tech_name)
  local force = game.forces[force_name]
  local tech = force and force.technologies[tech_name]
  return tech ~= nil and tech.researched
end

--- Ability / building flags: "steam", "overcharge", "scanner".
function research.flag(force_name, flag)
  local f = R().flags[force_name]
  return f ~= nil and f[flag] == true
end

function research.hauler_slots(force_name) return R().hauler_slots[force_name] or 0 end
function research.robots_per_hub_bonus(force_name) return R().hub_robots[force_name] or 0 end
function research.armor(force_name) return R().armor[force_name] or 0 end
function research.uses_mk2(force_name) return R().mk2[force_name] == true end

--- Why a barracks holds a kit: {reason = "locked" | "supply", tech?, unit, tick, used?, cap?} or nil.
function research.block_of(unit_number)
  local rec = storage.buildings and storage.buildings[unit_number]
  return rec and rec.research_block
end

--- "done" | "researching" | "queued" | "available" | "locked" (prerequisites missing) | "disabled"
function research.status(force_name, tech_name, queue_set)
  local force = game.forces[force_name]
  local tech = force and force.technologies[tech_name]
  if not tech then return "disabled" end
  if tech.researched then return "done" end
  local cur = force.current_research
  if cur and cur.name == tech_name then return "researching" end
  if not queue_set then
    queue_set = {}
    for _, t in ipairs(force.research_queue or {}) do queue_set[t.name] = true end
  end
  if queue_set[tech_name] then return "queued" end
  if not tech.enabled then return "disabled" end
  for _, pre in pairs(tech.prerequisites) do
    if not pre.researched then return "locked" end
  end
  return "available"
end

--- {name, progress 0..1} of the force's current research, or nil.
function research.current(force_name)
  local force = game.forces[force_name]
  local cur = force and force.current_research
  if not cur then return nil end
  return {name = cur.name, progress = force.research_progress}
end

--- Queue a technology (added to the back of the research queue). Returns ok, reason.
function research.queue(force_name, tech_name)
  ensure(force_name)
  local force = game.forces[force_name]
  if not force then return false, "no force" end
  local status = research.status(force_name, tech_name)
  if status ~= "available" then
    util.log("research: %s cannot queue %s: %s", force_name, tech_name, status)
    return false, status
  end
  local ok = force.add_research(tech_name)
  local queue = {}
  for _, t in ipairs(force.research_queue or {}) do queue[#queue + 1] = t.name end
  util.log("research: %s queued %s: %s, queue [%s]", force_name, tech_name, tostring(ok), table.concat(queue, " "))
  return ok, ok and "queued" or "refused"
end

--- Remove a technology from the queue (cancels it when it is the current research). Returns true when removed.
function research.cancel(force_name, tech_name)
  ensure(force_name)
  local force = game.forces[force_name]
  if not force then return false end
  local keep, found = {}, false
  for _, t in ipairs(force.research_queue or {}) do
    if t.name == tech_name then found = true else keep[#keep + 1] = t.name end
  end
  if found then force.research_queue = keep end
  util.log("research: %s cancelled %s: %s", force_name, tech_name, tostring(found))
  return found
end

---------------------------------------------------------------------------
-- Barracks gate (production.kit_gate)
---------------------------------------------------------------------------
local function exempt(force_name)
  return research.AI_IGNORES_LOCKS and storage.ai ~= nil and storage.ai[force_name] ~= nil
end

local function block(rec, b)
  local old = rec.research_block
  b.tick = game.tick
  rec.research_block = b
  R().blocked[rec.force] = b
  if old and old.reason == b.reason and old.unit == b.unit then return end
  util.log("research: barracks #%d (%s) holds a kit: %s %s%s", rec.entity.unit_number, rec.force, b.reason, b.unit,
    b.tech and (" needs " .. b.tech) or string.format(" (supply %d/%d)", b.used or -1, b.cap or -1))
  if b.reason == "locked" then
    local r = R()
    r.lock_alerts = r.lock_alerts or {}
    local last = r.lock_alerts[rec.force]
    if not last or game.tick - last >= research.LOCK_ALERT_PERIOD then
      r.lock_alerts[rec.force] = game.tick
      local params = {{"entity-name." .. b.unit}, {"technology-name." .. b.tech}}
      supply.alert(rec.force, "unit-locked", "rts.alert-unit-locked", params, rec.entity.position)
      local force = game.forces[rec.force]
      if force then force.print({"rts.alert-unit-locked", params[1], params[2]}) end
    end
  end
end

--- Decide what a finished kit becomes: a def {unit, kind} to spawn, or nil (the kit stays in the output).
function research.gate(rec, kit, def)
  local force_name = rec.force
  ensure(force_name)
  local tech = research.LOCKS[def.unit] or research.LOCKS[kit]
  if tech and not research.is_unlocked(force_name, def.unit) and not exempt(force_name) then
    block(rec, {reason = "locked", tech = tech, unit = def.unit, kit = kit})
    return nil
  end
  local spawn = def
  if research.MK2_AUTO and R().mk2[force_name] then
    local mk2 = research.mk2_of(def.unit)
    if mk2 then spawn = {unit = mk2, kind = def.kind, base = def.unit} end
  end
  local ok, used, cap = supply.can_spawn(force_name, spawn.unit)
  if not ok then
    block(rec, {reason = "supply", unit = spawn.unit, kit = kit, used = used, cap = cap})
    supply.blocked(force_name, spawn.unit, rec.entity.position, used, cap)
    return nil
  end
  if rec.research_block then
    util.log("research: barracks #%d (%s) released (%s cleared)", rec.entity.unit_number, force_name,
      rec.research_block.reason)
    rec.research_block = nil
    if R().blocked[force_name] then R().blocked[force_name] = nil end
  end
  return spawn
end

production.kit_gate = research.gate

---------------------------------------------------------------------------
-- Labs
---------------------------------------------------------------------------
local function set_lab_state(rec, state)
  if rec.lab_state == state then return end
  rec.lab_state = state
  util.log("research: lab #%d (%s) %s", rec.entity.unit_number, rec.force, state)
end

local function feed_lab(rec, current)
  local e = rec.entity
  if not current then
    set_lab_state(rec, "idle")
    return
  end
  local network = production.network_for(e)
  if not network then
    set_lab_state(rec, "no network")
    return
  end
  local inv = e.get_inventory(defines.inventory.lab_input)
  local short
  for _, ing in ipairs(current.research_unit_ingredients) do
    local have = inv.get_item_count(ing.name)
    if have < research.LAB_MIN then
      local got = network.remove_item({name = ing.name, count = research.LAB_FEED - have})
      if got > 0 then
        local put = inv.insert({name = ing.name, count = got})
        if put < got then network.insert({name = ing.name, count = got - put}) end
      end
      if have + got == 0 then short = ing.name end
    end
  end
  set_lab_state(rec, short and ("starved: " .. short) or "researching")
end

--- {labs, working} of a force (working = has kits for the current research).
function research.lab_counts(force_name)
  local n, working = 0, 0
  for _, rec in buildings.for_force(force_name, "lab") do
    n = n + 1
    if rec.lab_state == "researching" then working = working + 1 end
  end
  return n, working
end

events.on_nth_tick(research.LAB_PERIOD, function()
  local r = R()
  if not r then return end
  research.sync()
  for _, force in pairs(game.forces) do
    if is_rts_force(force) and not r.forces[force.name] then research.init_force(force) end
  end
  if not storage.buildings then return end
  local current = {}
  for _, rec in buildings.all("lab") do
    local cur = current[rec.force]
    if cur == nil then
      local force = game.forces[rec.force]
      cur = force and force.current_research or false
      current[rec.force] = cur
    end
    feed_lab(rec, cur or nil)
  end
end)

---------------------------------------------------------------------------
-- Armor II/III: heal back a share of the damage
---------------------------------------------------------------------------
--- on_entity_damaged handler (exposed for the cost probe).
function research.on_damaged(e)
  local entity = e.entity
  if not (entity and entity.valid) then return end
  local r = R()
  local share = r and r.armor[entity.force.name]
  if not share or e.final_health <= 0 or not derive().armored[entity.name] then return end
  local heal = e.final_damage_amount * share
  if heal <= 0 then return end
  entity.health = entity.health + heal
  local s = r.stats
  s.heals = s.heals + 1
  s.healed = s.healed + heal
end

events.on(defines.events.on_entity_damaged, research.on_damaged)
do
  -- The filter replaces scripts/ai/init.lua's (building names only), so it keeps every RTS building name (the
  -- registry's, balance.buildings and the hub, whose modules may load later) and adds the armored unit names.
  -- Set at load, after ai.init (control.lua order), identically on every load.
  local seen, names = {}, {}
  local function add(name)
    if not seen[name] and prototypes.entity[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  for name in pairs(buildings.KIND_BY_NAME) do add(name) end
  for name in pairs(balance and balance.buildings or {}) do add(name) end -- registered later by their modules
  add("rts-hub")
  table.sort(names)
  local armored = {}
  for name in pairs(derive().armored) do armored[#armored + 1] = name end
  table.sort(armored)
  for _, name in ipairs(armored) do names[#names + 1] = name end
  local filters = {}
  for _, name in ipairs(names) do filters[#filters + 1] = {filter = "name", name = name} end
  script.set_event_filter(defines.events.on_entity_damaged, filters)
  research.ARMORED_NAMES = armored
end

---------------------------------------------------------------------------
-- Research events
---------------------------------------------------------------------------
events.on(defines.events.on_force_created, function(e)
  if R() and is_rts_force(e.force) then research.init_force(e.force) end
end)

events.on(defines.events.on_research_finished, function(e)
  local tech = e.research
  if not (tech and tech.valid and is_rts_name(tech.name)) then return end
  local force = tech.force
  if not is_rts_force(force) then return end
  research.sync()
  if not R().forces[force.name] then research.init_force(force) end
  local t = research.apply(force)
  util.log("research: %s finished %s%s at tick %d; researched [%s]", force.name, tech.name,
    e.by_script and " (by script)" or "", e.tick, table.concat(t.techs, " "))
  supply.alert(force.name, "research-complete", "rts.alert-research-complete", {tech.localised_name})
  force.print({"rts.alert-research-complete", tech.localised_name})
end)

events.on(defines.events.on_research_reversed, function(e)
  local tech = e.research
  if not (tech and tech.valid and is_rts_name(tech.name)) or R().resetting then return end
  if is_rts_force(tech.force) then research.apply(tech.force) end
end)

function research.debug_line(force_name)
  local force = game.forces[force_name]
  if not force then return force_name .. ": no force" end
  local t = compute(force)
  local cats = {}
  for _, cat in ipairs(derive().unit_categories) do
    cats[#cats + 1] = string.format("%s=%.2f", cat, force.get_ammo_damage_modifier(cat))
  end
  local cur = research.current(force_name)
  local s = supply.get(force_name)
  return string.format("%s: researched [%s] current %s ammo [%s] mining %.2f robots speed %.2f storage %.0f "
    .. "supply %d/%d armor %.2f mk2 %s", force_name, table.concat(t.techs, " "),
    cur and string.format("%s %.0f%%", cur.name, cur.progress * 100) or "-", table.concat(cats, " "),
    force.mining_drill_productivity_bonus, force.worker_robots_speed_modifier, force.worker_robots_storage_bonus,
    s.used, s.cap, research.armor(force_name), tostring(research.uses_mk2(force_name)))
end

return research
