-- Phase 5 M2 diplomacy GUI probe (tools/gui-run.sh; charting needs a real client): a Nation 1v1, then an alliance between
-- rts-player and rts-ai-1. Checks that the player's force has the ally's base charted (shared charts, fog.lua charting
-- allies) and that it had not before the alliance. Log "[rts] dgui ...", marker "DGUI done".
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local diplomacy = require("scripts.diplomacy")
local lobby = require("scripts.lobby")
local fog = require("scripts.fog")

local function chunk_of(p) return {math.floor(p.x / 32), math.floor(p.y / 32)} end

events.on_nth_tick(60, function(e)
  local s = storage.dgui or {}
  storage.dgui = s
  if s.done then return end
  local m = storage.match
  if not s.started and e.tick >= 180 then
    s.started = true
    lobby.start_match({opponents = 2, difficulty = "normal", mode = "nation", world_size = 1536, enemy_brain = "ai"}, "dgui")
    util.log("dgui: match started")
    return
  end
  if not (m and m.phase == "running" and m.tick_started) then return end
  local age = (e.tick - m.tick_started) / 60
  local P, A = game.forces["rts-player"], game.forces["rts-ai-1"]
  local surface = match.surface()
  local home_a = diplomacy.capital_position("rts-ai-1")
  if age >= 10 and not s.before then
    s.before = true
    util.log("dgui: before: player charted ally capital chunk %s = %s, ally charted it = %s, share_chart %s/%s",
      serpent.line(chunk_of(home_a)), tostring(P.is_chunk_charted(surface, chunk_of(home_a))),
      tostring(A.is_chunk_charted(surface, chunk_of(home_a))), tostring(P.share_chart), tostring(A.share_chart))
    diplomacy.set_state("rts-player", "rts-ai-1", "alliance", "dgui")
    util.log("dgui: alliance set: friend %s/%s, share_chart %s/%s, charted forces %s", tostring(P.get_friend(A)),
      tostring(A.get_friend(P)), tostring(P.share_chart), tostring(A.share_chart),
      table.concat(fog.charted_forces(), ","))
  elseif age >= 25 and not s.after then
    s.after = true
    local n_p, n_a, total = 0, 0, 0
    for dx = -2, 2 do
      for dy = -2, 2 do
        local c = {chunk_of(home_a)[1] + dx, chunk_of(home_a)[2] + dy}
        total = total + 1
        if P.is_chunk_charted(surface, c) then n_p = n_p + 1 end
        if A.is_chunk_charted(surface, c) then n_a = n_a + 1 end
      end
    end
    util.log("dgui: after: around the ally capital %d/%d chunks charted for the player, %d/%d for the ally, visible %s",
      n_p, total, n_a, total, tostring(P.is_chunk_visible(surface, chunk_of(home_a))))
    local player = game.get_player(1)
    if player then
      player.set_controller({type = defines.controllers.remote, position = home_a, surface = surface})
      player.zoom = 0.15
      game.take_screenshot({player = player, position = home_a, zoom = 0.15, resolution = {1280, 800},
        path = "dgui-ally-capital.png", show_entity_info = false})
      util.log("dgui: screenshot of the ally capital at %s", util.pos_str(home_a))
    end
  elseif age >= 30 then
    s.done = true
    log("[rts] DGUI done")
  end
end)
