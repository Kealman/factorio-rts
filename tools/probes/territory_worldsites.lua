-- Test copy only (tools/autotest-run.sh EXTRA_LUA): a stand-in storage.world (size 512, city sites) until scripts/world.lua
-- exists, so the AI's second city takes the world-site path of cities.ai_step. Sites: one per side 150-190 tiles from
-- the large arena's spawns (x = -216 and 216), one in the middle, one ruin (ignored).
local events = require("scripts.events")
events.on_init(function()
  storage.world = {size = 512, stand_in = true, sites = {
    {kind = "city_site", position = {x = -110, y = -120}},
    {kind = "city_site", position = {x = 110, y = 120}},
    {kind = "city_site", position = {x = 0, y = -150}},
    {kind = "ruin", position = {x = 0, y = 0}},
  }}
end)
