-- Phase 1 stub. Will own the `order`, `target` and `dest` fields of storage.units records:
-- move / attack / attack-move / stop / hold for a selection, attack re-targeting on
-- on_ai_command_completed. See docs/qa/phase1-skeleton-notes.md for the hooks.
local util = require("scripts.util")

local orders = {}

function orders.init()
  util.log("orders: stub")
end

return orders
