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

local function nth_dispatcher(list, n)
  local plain = dispatcher(list)
  return function(event)
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

return events
