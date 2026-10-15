-- Keeps the rts-cursor selection tool in the player's hand (spike #1/#2, decision 13):
-- given on setup, re-inserted when the cursor empties (Q, controller changes), F1 forces it back.
--
-- Phase 2 build mode: the build menu (hud.lua) puts a ghost in the cursor with cursor.give_ghost. While a
-- ghost is in the cursor the tool is NOT re-inserted, so the player can place several ghosts in a row.
-- Build mode ends when the cursor is cleared: Q (vanilla clear-cursor, followed by the rts-clear-cursor input),
-- a right click (orders.lua), F1, or the build button of the same item. The tool then comes back through
-- on_player_cursor_stack_changed, the rts-clear-cursor input or, as a backstop, the WATCHDOG_TICKS sweep.
local util = require("scripts.util")
local events = require("scripts.events")

local cursor = {}

local CONTROLLERS_WITH_CURSOR = {
  [defines.controllers.remote] = true,
  [defines.controllers.god] = true,
}
local WATCHDOG_TICKS = 10

-- Re-entry guard for the duration of one call (set_stack can raise on_player_cursor_stack_changed).
-- Not game state, so it is fine as a module local.
local giving = false

--- Item name of the ghost in the player's cursor, or nil.
function cursor.ghost_name(player)
  local ghost = player.cursor_ghost
  if not ghost then return nil end
  local name = ghost.name
  if type(name) == "table" or type(name) == "userdata" then name = name.name end -- LuaItemPrototype on read
  return name
end

--- True when the player holds the RTS cursor tool.
function cursor.holds_tool(player)
  local stack = player.cursor_stack
  return stack ~= nil and stack.valid_for_read and stack.name == util.CURSOR_ITEM
end

--- Make sure the player holds the RTS cursor. Does nothing for character/spectator controllers.
--- With force_replace, anything else in the cursor is cleared first; otherwise a non-empty cursor
--- (something the player picked on purpose, or a build ghost) is left alone. Returns true if the cursor holds the tool.
--- `reason` only labels the QA log line "cursor given player=N reason=..." written when the tool is put back.
function cursor.ensure(player, force_replace, reason)
  if not (player and player.valid and CONTROLLERS_WITH_CURSOR[player.controller_type]) then return false end
  local stack = player.cursor_stack
  if not stack then return false end
  if stack.valid_for_read and stack.name == util.CURSOR_ITEM then return true end
  local occupied = stack.valid_for_read or player.cursor_ghost ~= nil
  if (occupied and not force_replace) or giving then return false end
  giving = true
  if occupied then player.clear_cursor() end
  if player.cursor_ghost ~= nil then player.cursor_ghost = nil end -- clear_cursor keeps a ghost in some states
  local ok = stack.set_stack({name = util.CURSOR_ITEM, count = 1})
  giving = false
  util.log("cursor given player=%d reason=%s ok=%s", player.index, reason or "setup", tostring(ok))
  return ok
end

--- Build mode: replace the RTS cursor with a ghost of `item` (vanilla ghost placement follows: left click
--- places, R rotates). Returns true when the ghost is in the cursor. On failure the tool is given back.
function cursor.give_ghost(player, item)
  if not (player and player.valid and CONTROLLERS_WITH_CURSOR[player.controller_type]) then return false end
  if not prototypes.item[item] then return false end
  local stack = player.cursor_stack
  giving = true -- the stack change below must not bring the tool straight back
  if stack and stack.valid_for_read then stack.clear() end -- the tool is only-in-cursor: it just vanishes
  player.cursor_ghost = item
  giving = false
  local ok = cursor.ghost_name(player) == item
  if not ok then cursor.ensure(player, true, "ghost refused") end
  return ok
end

events.on(defines.events.on_player_cursor_stack_changed, function(e)
  cursor.ensure(game.get_player(e.player_index), false, "cursor emptied")
end)

-- set_controller{god} creates a fresh controller with an empty cursor and no cursor event (spike #1 gotcha 6).
events.on(defines.events.on_player_controller_changed, function(e)
  cursor.ensure(game.get_player(e.player_index), false, "controller changed")
end)

events.on("rts-give-cursor", function(e)
  local player = game.get_player(e.player_index)
  local ghost = cursor.ghost_name(player)
  local ok = cursor.ensure(player, true, "F1")
  util.log("cursor F1 player=%d tool_in_hand=%s%s", e.player_index, tostring(ok),
    ghost and (" (ended build mode, ghost " .. ghost .. ")") or "")
end)

-- Follows the vanilla clear-cursor control (Q). The custom input is raised before the game clears the cursor,
-- so the tool is given back on the next tick (storage.cursor.pending), not here.
events.on("rts-clear-cursor", function(e)
  local player = game.get_player(e.player_index)
  if not player then return end
  local ghost = cursor.ghost_name(player)
  util.log("cursor clear (Q) player=%d ghost=%s", e.player_index, ghost or "none")
  storage.cursor = storage.cursor or {}
  storage.cursor.pending = storage.cursor.pending or {}
  storage.cursor.pending[e.player_index] = e.tick + 1
end)

events.on(defines.events.on_tick, function(e)
  local c = storage.cursor
  local pending = c and c.pending
  if not pending or next(pending) == nil then return end
  for index, due in pairs(pending) do
    if e.tick >= due then
      pending[index] = nil
      local player = game.get_player(index)
      if player and player.connected then cursor.ensure(player, false, "Q") end
    end
  end
end)

-- Backstop: clearing a cursor ghost is not guaranteed to raise on_player_cursor_stack_changed (the stack itself
-- stays empty), so an empty cursor without a ghost gets the tool back within WATCHDOG_TICKS.
events.on_nth_tick(WATCHDOG_TICKS, function()
  for _, player in pairs(game.connected_players) do
    local p = storage.players and storage.players[player.index]
    if p and p.setup_done and CONTROLLERS_WITH_CURSOR[player.controller_type] then
      local stack = player.cursor_stack
      if stack and not stack.valid_for_read and player.cursor_ghost == nil then
        cursor.ensure(player, false, "watchdog")
      end
    end
  end
end)

function cursor.init()
  storage.cursor = storage.cursor or {}
  storage.cursor.pending = storage.cursor.pending or {}
end

return cursor
