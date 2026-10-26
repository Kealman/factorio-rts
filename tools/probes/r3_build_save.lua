-- Release 0.1.2 r3-build: the owner's 0.1.1 save with this tree. Load-time probe (not the autotest): copy the mod tree to
-- a scratch mod dir, append require("scripts.r3_build_save") to its control.lua, start a headless server on a COPY of
-- build/saves/owner-0111-age2.zip for 120+ s. After 20 s the probe clicks an existing own belt, an inserter and a pole
-- (selection index 0), demolishes each with two presses, then box-selects up to 10 belts and removes them, and logs
-- "[rts] r3 save probe ..." lines.
local events = require("scripts.events")
local util = require("scripts.util")
local selection = require("scripts.selection")
local demolish = require("scripts.demolish")
local F = util.PLAYER_FORCE
local started, done = nil, false

events.on_nth_tick(60, function()
  if done then return end
  started = started or game.tick
  if game.tick - started < 1200 then return end
  done = true
  local surface = util.surface()
  local function click(e)
    local p = e.position
    selection.handle_area(0, {}, {left_top = {x = p.x - 0.02, y = p.y - 0.02}, right_bottom = {x = p.x + 0.02, y = p.y + 0.02}}, false, surface)
  end
  for _, name in ipairs({"transport-belt", "fast-inserter", "medium-electric-pole"}) do
    local e = surface.find_entities_filtered({force = F, name = name, limit = 1})[1]
    if e then
      click(e)
      local n = #selection.get_pieces(0)
      local r1 = demolish.request(0)
      local r2 = demolish.request(0)
      util.log("r3 save probe %s: selected=%d %s/%s gone=%s", name, n, tostring(r1), tostring(r2), tostring(not e.valid))
    else
      util.log("r3 save probe %s: none found in the save", name)
    end
  end
  local belts = surface.find_entities_filtered({force = F, name = "transport-belt", limit = 10})
  if #belts > 0 then
    local p = belts[1].position
    selection.handle_area(0, {}, {left_top = {x = p.x - 4, y = p.y - 4}, right_bottom = {x = p.x + 4, y = p.y + 4}}, false, surface)
    local n = #selection.get_pieces(0)
    util.log("r3 save probe box: selected=%d %s %s", n, tostring(demolish.request(0)), tostring(demolish.request(0)))
  end
  util.log("r3 save probe done")
end)
