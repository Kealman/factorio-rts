-- Phase 1 stub. Will own storage.players[i].selection / groups / boxes (docs/PHASE1.md):
-- the four on_player_*selected_area events of rts-cursor, selection boxes (rendering), control groups
-- (rts-group-set-N / rts-group-N), rts-select-all. See docs/qa/phase1-skeleton-notes.md for the hooks.
local util = require("scripts.util")

local selection = {}

function selection.init()
  util.log("selection: stub")
end

return selection
