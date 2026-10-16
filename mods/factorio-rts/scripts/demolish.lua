-- Demolish own buildings (docs/qa/phase5-m1-protocol-notes.md "Demolish"). The player-facing part of
-- buildings.demolish: the Demolish buttons (HUD building page, hub panel, city panel) and the rts-demolish input
-- (Delete, Backspace) call demolish.request(player_index [, unit_numbers]) with the selected building(s).
--
-- Two presses: the first arms ("Demolish N buildings? Press again", the button turns red), the second within
-- CONFIRM_TICKS on the same set executes. The Command Center and a capital City Center are never demolished (a
-- "cannot demolish" message). Done: refund and contents as in buildings.demolish, alert "Demolished X".
--
-- Owns storage.players[i].demolish = {key = "un,un,...", tick = tick it was armed}.
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local supply = require("scripts.supply")

local demolish = {}

demolish.CONFIRM_TICKS = 3 * 60

local function real_player(player_index)
  return selection.real_player(player_index)
end

local function say(player_index, message)
  local player = real_player(player_index)
  if not player then return end
  player.print(message)
  player.create_local_flying_text({text = message, create_at_cursor = true, time_to_live = 120})
end

-- Selected buildings: selection.get_buildings when the selection supports several, else the one building.
local function selected(player_index)
  if selection.get_buildings then return selection.get_buildings(player_index) end
  local un = selection.get_building(player_index)
  return un and {un} or {}
end

-- Own live records among `list` (default: the selection), unit numbers ascending. Second result: those that may
-- not be demolished, as {rec, reason}.
local function resolve(player_index, list)
  local force = selection.force_name(player_index)
  local ok, blocked = {}, {}
  for _, un in ipairs(list or selected(player_index)) do
    local rec = buildings.get(un)
    if rec and rec.force == force then
      local why = buildings.demolish_blocked(rec)
      if why then blocked[#blocked + 1] = {rec = rec, reason = why} else ok[#ok + 1] = un end
    end
  end
  table.sort(ok)
  return ok, blocked
end

local function key_of(list) return table.concat(list, ",") end

--- Number of buildings a request would demolish now, and whether the selection holds protected ones.
function demolish.preview(player_index, list)
  local ok, blocked = resolve(player_index, list)
  return #ok, #blocked
end

--- True while the player armed exactly the buildings that are selected (or `list`) and the time is not up.
function demolish.is_armed(player_index, list)
  local st = util.pstorage(player_index).demolish
  if not (st and game.tick - st.tick <= demolish.CONFIRM_TICKS) then return false end
  return st.key == key_of((resolve(player_index, list)))
end

-- Demolish the units; returns the number done and the list of infos. One alert per call.
local function execute(player_index, list)
  local force = selection.force_name(player_index)
  local exclude, carry, infos = {}, {}, {}
  for _, un in ipairs(list) do exclude[un] = true end
  for _, un in ipairs(list) do
    local rec = buildings.get(un)
    if rec then
      local ok, info = buildings.demolish(rec.entity, {force = force, exclude = exclude, carry = carry})
      if ok then infos[#infos + 1] = info else util.log("demolish: #%d refused: %s", un, tostring(info)) end
    end
  end
  if #infos > 0 then
    local first = infos[1]
    if #infos == 1 then
      supply.alert(force, "demolished", "rts.alert-demolished", {"[entity=" .. first.name .. "]",
                   {"entity-name." .. first.name}}, first.position)
    else
      supply.alert(force, "demolished", "rts.alert-demolished-many", {#infos}, first.position)
    end
  end
  return #infos, infos
end

--- Press of a Demolish button or of the key. `list` = unit numbers (default: the selected building(s)).
--- Returns "none" (nothing to demolish), "blocked" (only protected ones), "armed" or "done", and a count.
--- QA log lines: "demolish: armed|done player=N ...".
function demolish.request(player_index, list)
  local ok, blocked = resolve(player_index, list)
  if #ok == 0 then
    if #blocked > 0 then
      say(player_index, {"rts.demolish-blocked", {"entity-name." .. blocked[1].rec.entity.name}})
      util.log("demolish: blocked player=%d %s #%d (%s)", player_index, blocked[1].rec.kind,
        blocked[1].rec.entity.unit_number, blocked[1].reason)
      return "blocked", 0
    end
    return "none", 0
  end
  local p = util.pstorage(player_index)
  local key = key_of(ok)
  local st = p.demolish
  if not (st and st.key == key and game.tick - st.tick <= demolish.CONFIRM_TICKS) then
    p.demolish = {key = key, tick = game.tick}
    say(player_index, {"rts.demolish-armed", #ok})
    util.log("demolish: armed player=%d buildings=%d (%s)", player_index, #ok, key)
    selection.notify_hud(player_index)
    return "armed", #ok
  end
  p.demolish = nil
  local n, infos = execute(player_index, ok)
  if #blocked > 0 then say(player_index, {"rts.demolish-skipped", #blocked}) end
  local refund = {}
  for _, info in ipairs(infos) do
    for item, c in pairs(info.refund) do refund[item] = (refund[item] or 0) + c end
  end
  local shown = {}
  for item, c in pairs(refund) do shown[#shown + 1] = c .. " " .. item end
  table.sort(shown)
  util.log("demolish: done player=%d buildings=%d refund [%s]", player_index, n, table.concat(shown, ", "))
  selection.notify_hud(player_index)
  return "done", n
end

--- A Demolish button was clicked (hud.lua, hubgui.lua, citygui.lua). Same as the key.
function demolish.click(player, list)
  local result, n = demolish.request(player.index, list)
  util.log("demolish: click player=%d result=%s n=%d", player.index, result, n)
  return result, n
end

events.on("rts-demolish", function(e)
  if not real_player(e.player_index) then return end
  demolish.request(e.player_index)
end)

return demolish
