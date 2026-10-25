-- Tiny multi-handler event bus.
--
-- Factorio allows one handler per event per mod, so every module registers through this bus instead of
-- calling script.on_event directly. The bus registers each event with `script` once and calls the
-- handlers in registration order, which is the order control.lua requires the modules in.
--
-- All registration must happen while control.lua loads (identically on every load), never from inside
-- an event handler; otherwise saves that are loaded later would miss handlers and desync.
local events = {}

local handlers = {}      -- [defines.events.* or custom-input name] = {handler, ...}
local nth_handlers = {}  -- [tick period] = {handler, ...}
local init_handlers, load_handlers, config_handlers = {}, {}, {}

-- Opt-in profiling (events.enable_profiling, test copies only: tools/autotest-run.sh PERF=1). Each handler is
-- labelled at registration with the file that registered it; with profiling on, the dispatchers time every call
-- into one accumulating profiler per label and log the per-tick averages every PROFILE_PERIOD ticks. Profilers are
-- module-local (never in storage) and only reach the log, so they cannot desync anything.
local labels = {}        -- [handler] = "module" (always recorded: registration happens once per load)
local profile = nil      -- nil, or {[label] = {acc = LuaProfiler, calls = n}}
local laps = {}          -- lap profilers per nesting depth (a handler may raise events: entity.die(), raise_event)
local depth = 0
local PROFILE_PERIOD = 60 * 60

local function caller_label()
  local info = debug and debug.getinfo and debug.getinfo(3, "S")
  local src = info and info.source or "?"
  return string.match(src, "scripts/(.-)%.lua$") or string.match(src, "([^/]+)%.lua$") or src
end

local function timed(handler, event)
  local label = labels[handler] or "?"
  local p = profile[label]
  if not p then
    p = {acc = helpers.create_profiler(true), calls = 0}
    profile[label] = p
  end
  depth = depth + 1
  local lap = laps[depth]
  if not lap then
    lap = helpers.create_profiler(true)
    laps[depth] = lap
  end
  lap.reset() -- reset() zeroes and starts the clock; restart() would keep the time of earlier calls
  handler(event)
  lap.stop()
  depth = depth - 1
  p.acc.add(lap) -- an outer call's time includes the nested handlers it raised
  p.calls = p.calls + 1
end

local function dispatcher(list)
  return function(event)
    if profile then
      for i = 1, #list do timed(list[i], event) end
    else
      for i = 1, #list do list[i](event) end
    end
  end
end

-- Phase 5 M3 perf: test probes only (tools/probes/perf_marks.lua): every call of an on_nth_tick handler whose period is
-- at least trace_period is timed and logged as "[rts] perf call t<tick> d0 nth<period> <module>: <time>", so a slow
-- tick can be traced to the periodic handler that ran in it. Like the profiling above it only reaches the log.
local trace_period = nil
local trace_lap = nil
function events.trace_nth(min_period) trace_period = min_period end

-- Economy 0.1.1 (#8): in a running Nation match the handlers of every period of at least STAGGER_MIN ticks run on a
-- phase of their own (tick % n == phase) instead of all on tick % n == 0: about 25 handlers of period 60 (and those of
-- 30, 15, 10 ...) shared one tick, every 60-tick tick of the perf scene took over 3 ms of script (production, logistics,
-- strategic, mapgen ...), 340-425 such ticks in 5 minutes. A handler's phase comes from a stable key, its module, its
-- period and its place among that module's handlers of that period ("production@60#2"), hashed: a test probe's
-- handlers take phases of their own and never move the mod's (with phases by registration order a probe changed the
-- match it measured). Phases keep off the ticks of the AI commanders' slices (one every 5 ticks: scripts/ai/init.lua,
-- next_tick % 5 of each commander) where the period is a multiple of 5; they are logged once per build. A handler gets the nominal tick (the multiple of n it stands for) as event.tick,
-- so its own "e.tick % 3600 == 0" checks still work; game.tick is the real tick. Skirmish, the lobby and an ending
-- match keep phase 0 for all, so their order and timing do not change. The phases are rebuilt whenever the commanders'
-- residues differ from the ones they were built for (checked at every staggered dispatch); they depend on storage and
-- the load order only, so every peer and every load agrees.
local STAGGER_MIN = 10
local nth_keys = {}  -- [n] = {stable key of each handler, in list order} (events.on_nth_tick)
local key_count = {} -- ["module@n"] = handlers that module registered for period n so far
local function key_hash(key)
  local h = 0
  for i = 1, #key do h = (h * 31 + string.byte(key, i)) % 2147483647 end
  return h
end
local by_phase, phase_key = nil, nil -- [n] = {[phase] = {handler, ...}}; the commanders' residues they were built for
local stagger_periods = {}           -- the staggered periods, ascending (the on_tick loop's order)
local function nation_running()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation" and m.phase == "running"
end
local function ai_residues()
  local used, list = {}, {}
  for _, C in pairs(storage.ai or {}) do
    if type(C) == "table" and type(C.next_tick) == "number" then used[C.next_tick % 5] = true end
  end
  for r = 0, 4 do if used[r] then list[#list + 1] = r end end
  return used, table.concat(list, ",")
end
local function build_phases()
  local avoid, key = ai_residues()
  by_phase, phase_key, stagger_periods = {}, key, {}
  local periods = {}
  for n in pairs(nth_handlers) do periods[#periods + 1] = n end
  table.sort(periods)
  for _, n in ipairs(periods) do
    if n >= STAGGER_MIN then
      local allowed = {}
      for ph = 0, n - 1 do
        if n % 5 ~= 0 or not avoid[ph % 5] then allowed[#allowed + 1] = ph end
      end
      local t, parts = {}, {}
      for i, h in ipairs(nth_handlers[n]) do
        local key = nth_keys[n][i]
        local ph = allowed[key_hash(key) % #allowed + 1]
        t[ph] = t[ph] or {}
        local slot = t[ph]
        slot[#slot + 1] = h
        parts[#parts + 1] = key .. "=" .. ph
      end
      by_phase[n] = t
      stagger_periods[#stagger_periods + 1] = n
      log(string.format("[rts] events: stagger phases period %d (AI residues %s): %s", n,
        phase_key ~= "" and phase_key or "-", table.concat(parts, " ")))
    end
  end
end
-- (checked on every staggered dispatch, so a client that joins or loads mid-match builds the same phases at once)
local function ensure_phases()
  local _, key = ai_residues()
  if not by_phase or key ~= phase_key then build_phases() end
end
local function run_one(h, event, n)
  if trace_period and n >= trace_period then
    trace_lap = trace_lap or helpers.create_profiler(true)
    trace_lap.reset()
    if profile then timed(h, event) else h(event) end
    trace_lap.stop()
    log({"", string.format("[rts] perf call t%d d0 nth%d %s: ", game.tick, n, labels[h] or "?"), trace_lap})
  elseif profile then
    timed(h, event)
  else
    h(event)
  end
end

local function nth_dispatcher(list, n)
  local plain = dispatcher(list)
  return function(event)
    if n >= STAGGER_MIN and nation_running() then
      ensure_phases()
      for _, h in ipairs(by_phase[n][0] or {}) do run_one(h, event, n) end
      return
    end
    if not (trace_period and n >= trace_period) then return plain(event) end
    trace_lap = trace_lap or helpers.create_profiler(true)
    for i = 1, #list do
      local lap = trace_lap
      lap.reset()
      if profile then timed(list[i], event) else list[i](event) end
      lap.stop()
      log({"", string.format("[rts] perf call t%d d0 nth%d %s: ", event.tick, n, labels[list[i]] or "?"), lap})
    end
  end
end

--- Register a handler for a defines.events id or a custom-input name. The handler receives the event table.
function events.on(event_id, handler)
  assert(event_id ~= nil, "events.on: event id is nil (typo in a defines.events name?)")
  local list = handlers[event_id]
  if not list then
    list = {}
    handlers[event_id] = list
    script.on_event(event_id, dispatcher(list))
  end
  list[#list + 1] = handler
  labels[handler] = labels[handler] or caller_label()
end

--- Test probes only (tools/probes): run the handlers registered for an event as the engine would. Built-in events such
--- as on_gui_click cannot be raised by script, so a GUI probe drives a button through this.
function events.dispatch(event_id, event)
  local list = handlers[event_id]
  if not list then return end
  for i = 1, #list do list[i](event) end
end

--- Register a handler that runs every n ticks (first call at tick 0). The handler receives NthTickEventData.
function events.on_nth_tick(n, handler)
  local list = nth_handlers[n]
  if not list then
    list = {}
    nth_handlers[n] = list
    script.on_nth_tick(n, nth_dispatcher(list, n)) -- Phase 5 M3 perf: nth_dispatcher (trace_nth)
  end
  list[#list + 1] = handler
  labels[handler] = labels[handler] or caller_label()
  -- Economy 0.1.1 (#8): the handler's stable key for the Nation stagger (see nth_dispatcher)
  local base = labels[handler] .. "@" .. n
  key_count[base] = (key_count[base] or 0) + 1
  nth_keys[n] = nth_keys[n] or {}
  nth_keys[n][#list] = base .. "#" .. key_count[base]
end

--- Test copies only: time every handler per registering module and log "[rts] perf ..." lines every minute (the
--- average milliseconds per tick of each module over that minute, worst first). Call it while control.lua loads,
--- after every module is required (tools/autotest-run.sh appends it to a copy's control.lua).
function events.enable_profiling()
  events.on_nth_tick(PROFILE_PERIOD, function(e)
    if not profile then
      profile = {}
      return
    end
    local names = {}
    for label in pairs(profile) do names[#names + 1] = label end
    table.sort(names)
    local parts = {"", string.format("[rts] perf tick %d, ms per tick averaged over %d ticks:", e.tick,
      PROFILE_PERIOD)}
    for _, label in ipairs(names) do
      local p = profile[label]
      p.acc.divide(PROFILE_PERIOD)
      parts[#parts + 1] = string.format(" | %s (%d calls) ", label, p.calls)
      parts[#parts + 1] = p.acc
      if #parts >= 18 then -- a LocalisedString takes at most 20 parameters
        log(parts)
        parts = {"", "[rts] perf (cont.)"}
      end
    end
    if #parts > 2 then log(parts) end
    profile = {}
  end)
end

-- Phase 5 M3 perf: true once enable_profiling's first minute has passed (scripts/sched.lua times its jobs then). Only
-- for logging: nothing may decide game state from it.
function events.profiling() return profile ~= nil end

-- Phase 5 M1: script signals between modules (docs/PHASE5-M1.md, e.g. "rts_territory_changed"). They are not engine
-- events: events.emit calls the handlers registered with events.on_signal synchronously, in registration order.
local signal_handlers = {} -- [signal name] = {handler, ...}

--- Register a handler for a script signal (load time only, like events.on). It receives the emitted data table.
function events.on_signal(name, handler)
  local list = signal_handlers[name]
  if not list then
    list = {}
    signal_handlers[name] = list
  end
  list[#list + 1] = handler
end

--- Emit a script signal to every handler registered for it. Returns the number of handlers called.
function events.emit(name, data)
  local list = signal_handlers[name]
  if not list then return 0 end
  for i = 1, #list do list[i](data) end
  return #list
end
events.raise = events.emit

--- Called once when the mod is first added to a save (new game or existing save).
function events.on_init(fn) init_handlers[#init_handlers + 1] = fn end

--- Called on every load of a save that already had the mod. `storage` is read-only here.
function events.on_load(fn) load_handlers[#load_handlers + 1] = fn end

--- Called when the mod set or a mod version changed. The handler receives ConfigurationChangedData.
function events.on_configuration_changed(fn) config_handlers[#config_handlers + 1] = fn end

script.on_init(function()
  for i = 1, #init_handlers do init_handlers[i]() end
end)

script.on_load(function()
  for i = 1, #load_handlers do load_handlers[i]() end
end)

script.on_configuration_changed(function(data)
  for i = 1, #config_handlers do config_handlers[i](data) end
end)

-- Economy 0.1.1 (#8): the staggered phases of a running Nation match (see nth_dispatcher above)
events.on(defines.events.on_tick, function(e)
  if not nation_running() then return end
  local tick = e.tick
  ensure_phases()
  for _, n in ipairs(stagger_periods) do
    local r = tick % n
    if r ~= 0 then
      local list = by_phase[n][r]
      if list then
        local ev = {name = defines.events.on_tick, tick = tick - r, nth_tick = n}
        for i = 1, #list do run_one(list[i], ev, n) end
      end
    end
  end
end)

return events
