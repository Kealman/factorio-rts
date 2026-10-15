-- Keeps the rts-cursor selection tool in the player's hand (spike #1/#2, decision 13):
-- given on setup, re-inserted when the cursor empties (Q, controller changes), F1 forces it back.
local util = require("scripts.util")
local events = require("scripts.events")

local cursor = {}

local CONTROLLERS_WITH_CURSOR = {
  [defines.controllers.remote] = true,
  [defines.controllers.god] = true,
}

-- Re-entry guard for the duration of one call (set_stack can raise on_player_cursor_stack_changed).
-- Not game state, so it is fine as a module local.
local giving = false

--- Make sure the player holds the RTS cursor. Does nothing for character/spectator controllers.
--- With force_replace, anything else in the cursor is cleared first; otherwise a non-empty cursor
--- (something the player picked on purpose) is left alone. Returns true if the cursor holds the tool.
function cursor.ensure(player, force_replace)
  if not (player and player.valid and CONTROLLERS_WITH_CURSOR[player.controller_type]) then return false end
  local stack = player.cursor_stack
  if not stack then return false end
  if stack.valid_for_read and stack.name == util.CURSOR_ITEM then return true end
  local occupied = stack.valid_for_read or player.cursor_ghost ~= nil
  if (occupied and not force_replace) or giving then return false end
  giving = true
  if occupied then player.clear_cursor() end
  local ok = stack.set_stack({name = util.CURSOR_ITEM, count = 1})
  giving = false
  return ok
end

events.on(defines.events.on_player_cursor_stack_changed, function(e)
  cursor.ensure(game.get_player(e.player_index))
end)

-- set_controller{god} creates a fresh controller with an empty cursor and no cursor event (spike #1 gotcha 6).
events.on(defines.events.on_player_controller_changed, function(e)
  cursor.ensure(game.get_player(e.player_index))
end)

events.on("rts-give-cursor", function(e)
  cursor.ensure(game.get_player(e.player_index), true)
end)

return cursor
