-- Default map settings for NEW maps. Existing saves keep their own copy (game.map_settings at runtime).
local ms = data.raw["map-settings"]["map-settings"]

-- Units whose behaviour keeps failing are destroyed after this many failures (default 3).
-- RTS units must never be deleted by the engine for that reason.
ms.max_failed_behavior_count = 1000000

-- The RTS has its own AI; vanilla biters must not expand or evolve.
ms.enemy_expansion.enabled = false
ms.enemy_evolution.enabled = false
