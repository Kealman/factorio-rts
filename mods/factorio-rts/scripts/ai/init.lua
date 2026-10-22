-- AI commanders (docs/PHASE3.md "AI architecture"): entry point. control.lua requires this after scripts.match.
--
--   ai.init()                              on_init / on_configuration_changed: storage (lobby.lua starts the
--                                          commanders of a match; with the older match.lua, rts-enemy's here)
--   ai.init_force(force_name, difficulty)  start (or restart with another difficulty) a commander for a force
--   ai.stop_force(force_name)              forget a force's commander (its units and buildings stay)
--   ai.get(force_name)                     the commander state, or nil
--   ai.tick(event)                         scheduler: every TICK ticks, runs each commander that is due (each
--                                          commander every commander.THINK ticks, staggered by force)
-- Console: /rts-ai <force> [easy|normal|hard], /rts-ai-stop <force>, /rts-ai-dump [force], /rts-ai-map [force],
-- /rts-ai-doctrine <force> <economic|aggressive|turtle>.
-- Events: on_entity_damaged (filtered to RTS building names) feeds the army's threat; production.on_spawned gives
-- the hard bonus units.
-- Phase 4: at its end this file requires scripts.supply, scripts.research and scripts.logistics into ai/deps.lua
-- (research must set its damage filter after ours). AI commanders research their unlocks themselves (ai/tech.lua)
-- and obey the barracks gate like a player.
--
-- Owns storage.ai = {[force_name] = commander state (ai/commander.lua)} and storage.ai_meta = {inserter_dir_is_pickup,
-- doctrines = {[force] = doctrine override}, patch_claims = {[patch id] = force}}.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local data = require("scripts.ai.orders_data")
local commander = require("scripts.ai.commander")
local army = require("scripts.ai.army")
local layout = require("scripts.ai.layout")
local doctrine = require("scripts.ai.doctrine")
local deps = require("scripts.ai.deps")

local ai = {}

ai.TICK = 10
-- Phase 5 M3 perf: Nation mode runs each commander in commander.SLICES slices NATION_SLICE_GAP ticks apart, driven every
-- tick (ai.nation_tick) instead of every ai.TICK; the run start offsets by creation order put every slice of up to six
-- nations on a tick of its own (4 nations: slices on ticks 0, 5, 10 | 15, 20, 25 | 30, 35, 40 | 45, 50, 55 of each
-- THINK period; nations 5 and 6 add 7, 12, 17 | 37, 42, 47). NATION_SLICES off (a test copy) restores the Phase 4 runs.
ai.NATION_OFFSETS = {0, 30, 15, 45, 7, 37}
ai.NATION_SLICE_GAP = 5
ai.NATION_SLICES = true

local function nation_match()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

-- Wall-clock and AI-time profilers for the performance log (ai/autotest.lua). Module-local: profilers are not
-- game state and are not saved; after a load they are created again.
local perf = {}

local function ensure_storage()
  storage.ai = storage.ai or {}
  storage.ai_meta = storage.ai_meta or {}
  storage.ai_meta.doctrines = storage.ai_meta.doctrines or {}
  storage.ai_meta.patch_claims = storage.ai_meta.patch_claims or {}
end

function ai.init()
  ensure_storage()
  for _, C in pairs(storage.ai) do layout.tmigrate(C) end -- Phase 5 M3 perf: tile sets (saves from before M3)
  -- The Phase 3 match flow (match.lua with m.ai_forces) starts commanders from lobby.lua when a match starts. Only
  -- the older single-enemy match.lua relied on this to start the rts-enemy commander.
  local m = storage.match
  local cfg = m and m.config
  if m and not m.ai_forces and cfg and cfg.enemy_brain == "ai" and game.forces[util.ENEMY_FORCE]
     and not storage.ai[util.ENEMY_FORCE] then
    ai.init_force(util.ENEMY_FORCE, cfg.enemy_difficulty or data.DEFAULT_DIFFICULTY)
  end
end

--- The commander of a force, or nil.
function ai.get(force_name)
  return storage.ai and storage.ai[force_name]
end

--- Start a commander for `force_name` at `difficulty` (default normal). When the force already has one, only its
--- difficulty changes (settings and build order; the plan, the base and the army stay; start cheats are not given
--- again). Returns the commander or nil, reason.
function ai.init_force(force_name, difficulty)
  ensure_storage()
  if not game.forces[force_name] then return nil, "unknown force " .. tostring(force_name) end
  local old = storage.ai[force_name]
  if old then
    commander.set_difficulty(old, difficulty)
    return old
  end
  local C = commander.new(force_name, difficulty)
  -- stagger: commanders of different forces run on different ticks
  local slot = 0
  for _ in pairs(storage.ai) do slot = slot + 1 end
  if ai.NATION_SLICES and nation_match() then
    -- Phase 5 M3 perf: in Nation mode a run takes commander.SLICES slices NATION_SLICE_GAP ticks apart; these offsets
    -- give every slice of up to six nations a tick of its own (ai.NATION_OFFSETS)
    C.slice_offset = ai.NATION_OFFSETS[slot % #ai.NATION_OFFSETS + 1]
    C.next_tick = game.tick + 1 + C.slice_offset
  else
    C.next_tick = game.tick + 1 + (slot * 20) % commander.THINK
  end
  storage.ai[force_name] = C
  commander.start(C)
  return C
end

function ai.stop_force(force_name)
  if storage.ai and storage.ai[force_name] then
    storage.ai[force_name] = nil
    -- patches it claimed are free again (a new match starts new commanders)
    local claims = storage.ai_meta and storage.ai_meta.patch_claims or {}
    for id, f in pairs(claims) do
      if f == force_name then claims[id] = nil end
    end
    util.log("ai %s: commander stopped", force_name)
    return true
  end
  return false
end

--- Set the doctrine of a force: a running commander switches now (commander.set_doctrine); the override also
--- applies to the force's next commander. nil clears the override. Returns true when valid.
function ai.set_doctrine(force_name, name)
  ensure_storage()
  if name ~= nil and not doctrine.DEF[name] then return false end
  storage.ai_meta.doctrines[force_name] = name
  local C = storage.ai[force_name]
  if C and name and C.doctrine ~= name then commander.set_doctrine(C, name) end
  return true
end

--- Profilers {ai = time spent in commander runs, runs = number of runs, parts = {[subsystem] = profiler}} since
--- the last ai.reset_perf().
function ai.perf()
  if not perf.ai then
    perf.ai = helpers.create_profiler(true)
    perf.runs = 0
    perf.parts = {}
    for _, name in ipairs(commander.PARTS) do perf.parts[name] = helpers.create_profiler(true) end
    commander.set_profilers(perf.parts)
  end
  return perf
end

function ai.reset_perf()
  local p = ai.perf()
  p.ai.reset()
  p.ai.stop()
  for _, prof in pairs(p.parts) do
    prof.reset()
    prof.stop()
  end
  p.runs = 0
end

function ai.tick(e)
  local list = storage.ai
  if not list or next(list) == nil then return end
  if ai.NATION_SLICES and nation_match() then return end -- Phase 5 M3 perf: ai.nation_tick runs Nation commanders
  local p = ai.perf()
  for _, C in pairs(list) do
    if e.tick >= C.next_tick then
      C.next_tick = C.next_tick + commander.THINK
      if C.next_tick <= e.tick then C.next_tick = e.tick + commander.THINK end
      p.ai.restart()
      commander.run(C)
      p.ai.stop()
      p.runs = p.runs + 1
    end
  end
end

--- Phase 5 M3 perf: the Nation driver (every tick): slice 1 of a commander when it is due, slices 2 and 3
--- NATION_SLICE_GAP ticks apart after it (commander.run(C, k)).
function ai.nation_tick(e)
  local list = storage.ai
  if not list or next(list) == nil or not (ai.NATION_SLICES and nation_match()) then return end
  -- once per match: the commanders of a save from before M3 (Phase 4 stagger) get the Nation offsets, by force name
  local meta = storage.ai_meta
  local key = storage.match.tick_started or 0
  if meta and meta.sliced_match ~= key then
    meta.sliced_match = key
    local names = {}
    for f, C in pairs(list) do
      if not C.slice_offset then names[#names + 1] = f end
    end
    table.sort(names)
    for i, f in ipairs(names) do
      local C = list[f]
      C.slice_offset = ai.NATION_OFFSETS[(i - 1) % #ai.NATION_OFFSETS + 1]
      C.next_tick = e.tick + 1 + C.slice_offset
    end
  end
  local p
  -- Phase 5 M3 ai (determinism, m3-perf's audit): commanders in force-name order (two may share a tick from the 7th on)
  local names = {}
  for f in pairs(list) do names[#names + 1] = f end
  table.sort(names)
  for _, f in ipairs(names) do
    local C = list[f]
    if C.slice then
      if e.tick >= C.slice_tick then
        p = p or ai.perf()
        p.ai.restart()
        commander.run(C, C.slice)
        p.ai.stop()
        if C.slice < commander.SLICES then
          C.slice, C.slice_tick = C.slice + 1, e.tick + ai.NATION_SLICE_GAP
        else
          C.slice, C.slice_tick = nil, nil
        end
      end
    elseif e.tick >= C.next_tick then
      C.next_tick = C.next_tick + commander.THINK
      if C.next_tick <= e.tick then C.next_tick = e.tick + commander.THINK end
      p = p or ai.perf()
      p.ai.restart()
      commander.run(C, 1)
      p.ai.stop()
      p.runs = p.runs + 1
      C.slice, C.slice_tick = 2, e.tick + ai.NATION_SLICE_GAP
    end
  end
end

events.on_nth_tick(ai.TICK, ai.tick)
events.on(defines.events.on_tick, ai.nation_tick) -- Phase 5 M3 perf

-- Threats: damage to an own building of an AI force.
events.on(defines.events.on_entity_damaged, function(e)
  local entity = e.entity
  if not (entity and entity.valid) then return end
  if not buildings.KIND_BY_NAME[entity.name] then return end -- only RTS buildings are base threats (shared filter)
  local C = storage.ai and storage.ai[entity.force.name]
  if not C then return end
  local cause = e.cause
  if cause and cause.valid and cause.force == entity.force then return end
  army.on_damage(C, entity, cause, e.final_damage_amount)
end)
do
  -- Only RTS buildings raise the event for this mod (no other module listens to on_entity_damaged).
  local names = {}
  for name in pairs(buildings.KIND_BY_NAME) do names[#names + 1] = name end
  table.sort(names)
  local filters = {}
  for _, name in ipairs(names) do filters[#filters + 1] = {filter = "name", name = name} end
  script.set_event_filter(defines.events.on_entity_damaged, filters)
end

-- The last kit each AI barracks made (heavy-kit alternation, commander.lua), and hard's bonus units: every
-- kit_bonus_every-th unit an AI barracks spawns comes with a free one (production x1.25 at 4).
production.on_spawned(function(unit, rec, kit)
  local C = storage.ai and storage.ai[rec.force]
  if not C then return end
  C.last_kit = C.last_kit or {}
  if rec.entity.valid then C.last_kit[rec.entity.unit_number] = kit end
  C.last_spawn_tick = game.tick
  local every = C.cfg.kit_bonus_every
  if not every then return end
  C.spawned = (C.spawned or 0) + 1
  if C.spawned % every ~= 0 then return end
  if deps.supply and not deps.supply.can_spawn(rec.force, unit.name) then return end -- the bonus obeys the cap
  local extra = units.spawn(unit.name, unit.position, rec.force, nil, unit.surface)
  if extra then
    C.stats.bonus_units = C.stats.bonus_units + 1
    local rally = rec.rally
    if rally and extra.commandable then
      extra.commandable.set_command({type = defines.command.go_to_location, destination = rally, radius = 2,
                                     distraction = defines.distraction.none})
    end
  end
end)

---------------------------------------------------------------------------
-- Console commands
---------------------------------------------------------------------------
local function reply(cmd, line)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player then player.print(line) else game.print(line) end
  util.log("%s", line)
end

local function admin_only(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player and not player.admin then
    player.print("[rts] admins only")
    return false
  end
  return true
end

local function words(s)
  local out = {}
  for w in string.gmatch(s or "", "%S+") do out[#out + 1] = w end
  return out
end

--- Lines describing one commander or all of them.
function ai.dump_lines(force_name)
  local lines = {}
  for name, C in pairs(storage.ai or {}) do
    if not force_name or name == force_name then
      for _, l in ipairs(commander.dump_lines(C)) do lines[#lines + 1] = l end
    end
  end
  if #lines == 0 then lines[1] = "ai: no commander" .. (force_name and (" for " .. force_name) or "") end
  return lines
end

--- Log the ASCII plan map of each commander's base (layout.ascii): CC +-26 tiles in y, 24 tiles behind it to 44 in
--- front of it.
function ai.log_maps(force_name)
  local names = {}
  for name in pairs(storage.ai or {}) do
    if not force_name or name == force_name then names[#names + 1] = name end
  end
  table.sort(names)
  for _, f in ipairs(names) do
    local C = storage.ai[f]
    if C.frame then
      local fr = C.frame
      local xa, xb = fr.cx - 24 * fr.fx, fr.cx + 44 * fr.fx
      local x0, x1 = math.floor(math.min(xa, xb)), math.floor(math.max(xa, xb))
      local y0, y1 = math.floor(fr.cy) - 26, math.floor(fr.cy) + 26
      util.log("ai map %s (x %d..%d, y %d..%d):", f, x0, x1 - 1, y0, y1 - 1)
      for _, row in ipairs(layout.ascii(C, util.surface(), x0, y0, x1, y1)) do util.log("ai map %s %s", f, row) end
      -- forward hubs: 30 tiles around each
      local ids = {}
      for id in pairs(C.expansions or {}) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local X = C.expansions[id]
        if X.pos then
          local hx, hy = math.floor(X.pos.x), math.floor(X.pos.y)
          util.log("ai map %s hub %d (x %d..%d, y %d..%d):", f, id, hx - 30, hx + 29, hy - 30, hy + 29)
          for _, row in ipairs(layout.ascii(C, util.surface(), hx - 30, hy - 30, hx + 30, hy + 30)) do
            util.log("ai map %s hub%d %s", f, id, row)
          end
        end
      end
    end
  end
  return #names
end

local COMMANDS = {
  ["rts-ai"] = {
    help = "<force> [easy|normal|hard] - start (or restart) an AI commander for a force",
    admin = true,
    run = function(cmd)
      local args = words(cmd.parameter)
      local force_name, difficulty = args[1], args[2] or data.DEFAULT_DIFFICULTY
      if not force_name or not data.DIFFICULTY[difficulty] then
        reply(cmd, "rts-ai: usage /rts-ai <force> [easy|normal|hard]")
        return
      end
      local C, err = ai.init_force(force_name, difficulty)
      reply(cmd, C and string.format("rts-ai: commander for %s at %s", force_name, difficulty) or ("rts-ai: " .. err))
    end,
  },
  ["rts-ai-stop"] = {
    help = "<force> - stop the AI commander of a force (its units and buildings stay)",
    admin = true,
    run = function(cmd)
      local force_name = words(cmd.parameter)[1]
      reply(cmd, ai.stop_force(force_name or "") and ("rts-ai-stop: stopped " .. force_name)
        or "rts-ai-stop: no commander for " .. tostring(force_name))
    end,
  },
  ["rts-ai-map"] = {
    help = "[force] - write the ASCII plan map of the AI bases to the log",
    run = function(cmd)
      local n = ai.log_maps(words(cmd.parameter)[1])
      reply(cmd, string.format("rts-ai-map: %d map(s) written to the log", n))
    end,
  },
  ["rts-ai-doctrine"] = {
    help = "<force> <economic|aggressive|turtle> - set the doctrine of an AI force (now and for its next commander)",
    admin = true,
    run = function(cmd)
      local args = words(cmd.parameter)
      local ok = args[1] and ai.set_doctrine(args[1], args[2])
      reply(cmd, ok and string.format("rts-ai-doctrine: %s -> %s", args[1], args[2])
        or "rts-ai-doctrine: usage /rts-ai-doctrine <force> <economic|aggressive|turtle>")
    end,
  },
  ["rts-ai-dump"] = {
    help = "[force] - print the AI commander state",
    run = function(cmd)
      for _, line in ipairs(ai.dump_lines(words(cmd.parameter)[1])) do reply(cmd, line) end
    end,
  },
}

for name, def in pairs(COMMANDS) do
  commands.add_command(name, def.help, function(cmd)
    if def.admin and not admin_only(cmd) then return end
    def.run(cmd)
  end)
end

--- Run one of the /rts-ai* commands from script (the autotest): as the server console, or as `player_index`.
function ai.run_command(name, parameter, player_index)
  local def = COMMANDS[name]
  def.run({name = name, parameter = parameter, tick = game.tick, player_index = player_index})
end

-- Phase 4 modules that load after this one in control.lua (see the header and ai/deps.lua). research.lua sets the
-- union damage filter when it loads, i.e. here, after ours above.
deps.supply = require("scripts.supply")
deps.research = require("scripts.research")
deps.logistics = require("scripts.logistics")

return ai
