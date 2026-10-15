-- Control stage entry point.
--
-- Every module registers its event handlers through scripts/events.lua when it is first required, and
-- the bus calls handlers in that order. The order below is therefore load-bearing:
--   units first (registry), then the Phase 2 economy (buildings registry, production, economy summaries, base
--   template), match before camera (players are moved to the rts-player force and the lobby surface exists before
--   the camera is set up), fog after match, lobby after the HUD (its join handler shows the start dialog over the
--   freshly built HUD) and after ai.init (lobby.init stops commanders that ai.init started outside a match),
--   debug last.
-- Each module's init() is idempotent; it runs on on_init and again on on_configuration_changed.
local events = require("scripts.events")

local modules = {
  require("scripts.units"),
  require("scripts.buildings"),
  require("scripts.production"),
  require("scripts.economy"),
  require("scripts.basetemplate"),
  require("scripts.match"),
  require("scripts.ai.init"),  -- Phase 3 AI commanders; after match (ai.init reads storage.match.config)
  require("scripts.fog"),      -- Phase 3 fog of war (charts around own units and buildings)
  require("scripts.camera"),   -- also requires scripts.cursor
  require("scripts.cursor"),
  require("scripts.selection"),
  require("scripts.orders"),
  require("scripts.hud"),
  require("scripts.lobby"),    -- Phase 3 start dialog, menu, results; match start / restart
  require("scripts.debug"),
}

for _, module in ipairs(modules) do
  if module.init then
    events.on_init(module.init)
    events.on_configuration_changed(module.init)
  end
end
