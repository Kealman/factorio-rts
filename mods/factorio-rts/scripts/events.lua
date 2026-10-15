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

local function dispatcher(list)
  return function(event)
    for i = 1, #list do list[i](event) end
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
end

--- Register a handler that runs every n ticks (first call at tick 0). The handler receives NthTickEventData.
function events.on_nth_tick(n, handler)
  local list = nth_handlers[n]
  if not list then
    list = {}
    nth_handlers[n] = list
    script.on_nth_tick(n, dispatcher(list))
  end
  list[#list + 1] = handler
end

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
