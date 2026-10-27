-- Release 0.1.3 r4-hud (#38) headless probe: where do rations go? Starts a Nation match, waits for the capital's start
-- stock, gives 400 rations and 400 grain through economy.give, and logs the stock the strip would show (snapshot, market
-- network, stripgui.food_detail) every 10 s. Marker RTS_R4_FOOD_DONE. Run:
--   EXTRA_LUA=tools/probes/r4_food_headless.lua STOP_ON=RTS_R4_FOOD_DONE tools/autotest-run.sh r4food \
--     '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 512, enemy_brain = "ai"}' 200
local events = require("scripts.events")
local util = require("scripts.util")
local economy = require("scripts.economy")
local stripgui = require("scripts.stripgui")

local n = 0
events.on_nth_tick(600, function()
  if not (storage.match and storage.match.tick_started) then return end
  n = n + 1
  local F = "rts-player"
  if n == 3 then
    util.log("r4 food: give rations %d grain %d", economy.give(F, "rts-rations", 400), economy.give(F, "rts-grain", 400))
  end
  local snap = economy.snapshot(F)
  local d = stripgui.food_detail(F, "rts-rations")
  local g = stripgui.food_detail(F, "rts-grain")
  util.log("r4 food: n=%d snapshot rations=%s grain=%s | detail rations total=%s minutes=%s use=%.1f rows=%d | grain total=%s minutes=%s",
    n, tostring(snap.items["rts-rations"]), tostring(snap.items["rts-grain"]), tostring(d.total), tostring(d.minutes), d.use,
    #d.rows, tostring(g.total), tostring(g.minutes))
  if n >= 6 then util.log("RTS_R4_FOOD_DONE") end
end)
