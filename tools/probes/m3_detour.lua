-- Test-only (tools/autotest-run.sh EXTRA_LUA): Phase 5 M3 integration, a rail line blocked for good gets a detour
-- (scripts/rails.lua start_detour). The rails autotest's main stage (depots 800 tiles apart on its own surface) runs;
-- once its line is surveyed, a foreign stone furnace stands on a straight piece a third of the way, so the crew from
-- depot A cannot lay it. rails.DETOUR_AFTER is 30 s here. Checks: the line is blocked at that piece, a detour survey
-- replaces the pieces around it, and the line opens with no piece on the furnace (the autotest's own checks then run
-- a freight train over it, cut it and repair it). Log: "[rts] m3 detour check <name>: PASS|FAIL ...".
local rails = require("scripts.rails")
local events = require("scripts.events")
local util = require("scripts.util")
rails.AUTOTEST_DEFAULT = true
rails.AUTOTEST_STAGES = {"main"}
rails.DETOUR_AFTER = 30 * 60

local function S()
  storage.m3_detour = storage.m3_detour or {}
  return storage.m3_detour
end

local function check(name, ok, fmt, ...)
  util.log("m3 detour check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

events.on_nth_tick(30, function()
  local T = S()
  if T.done then return end
  local R = storage.rails
  if not (R and R.lines) then return end
  local line, low
  for id, l in pairs(R.lines) do
    if l.force == "rts-ai-3" and (not low or id < low) then line, low = l, id end
  end
  if line and not line.pieces then return end
  if not line then return end
  if not T.blocker then
    if line.state ~= "building" then return end
    -- a straight piece about a third of the way from depot A
    local k
    for i = math.floor(#line.pieces / 3), #line.pieces do
      local p = line.pieces[i]
      if p.name == "straight-rail" and not (p.e and p.e.valid) then
        k = i
        break
      end
    end
    if not k then return end
    local p = line.pieces[k]
    local s = game.surfaces[line.surface]
    local e = s.create_entity({name = "stone-furnace", position = {p.x, p.y}, force = "rts-ai-2"})
    T.blocker, T.k, T.pos, T.t0 = e and e.unit_number or -1, k, {x = p.x, y = p.y}, game.tick
    util.log("m3 detour: furnace %s on piece %d %s at %s of line #%d (%d pieces)", tostring(T.blocker), k, p.name,
      util.pos_str(T.pos), line.id, #line.pieces)
    return
  end
  if line.blocked and not T.blocked_at then
    T.blocked_at, T.blocked_piece = game.tick, line.blocked
    util.log("m3 detour: line #%d blocked at piece %d after %.0f s", line.id, line.blocked, (game.tick - T.t0) / 60)
  end
  if (line.detours or 0) > 0 and not T.detour_at then
    T.detour_at = game.tick
  end
  if line.state == "open" then
    local on = 0
    for _, p in ipairs(line.pieces) do
      if math.abs(p.x - T.pos.x) < 1.5 and math.abs(p.y - T.pos.y) < 1.5 then on = on + 1 end
    end
    check("blocked", T.blocked_piece == T.k, "line blocked at piece %s (the furnace stands on piece %d)",
      tostring(T.blocked_piece), T.k)
    check("detour", (line.detours or 0) >= 1 and on == 0, "%d detour(s), %d pieces at the furnace, line open %.0f s "
      .. "after the furnace: %d pieces, %d missing, bill %d rails", line.detours or 0, on, (game.tick - T.t0) / 60,
      #line.pieces, line.missing, line.rails or 0)
    T.done = true
  elseif game.tick - T.t0 > 15 * 60 * 60 then
    check("detour", false, "line #%d not open 15 min after the furnace: state %s, blocked %s, detours %d, missing %d",
      line.id, line.state, tostring(line.blocked), line.detours or 0, line.missing)
    T.done = true
  end
end)
