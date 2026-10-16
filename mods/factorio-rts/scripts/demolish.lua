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
  -- Phase 5 M1 integration: a refund that found no stockpile with room spilled on the ground: never silently
  local refund_spilled, at = 0, nil
  for _, info in ipairs(infos) do
    if (info.refund_spilled or 0) > 0 then
      refund_spilled = refund_spilled + info.refund_spilled
      at = at or info.position
    end
  end
  if refund_spilled > 0 then
    supply.alert(force, "demolished", "rts.alert-demolish-refund-spilled", {refund_spilled}, at)
    say(player_index, {"rts.alert-demolish-refund-spilled", refund_spilled})
    util.log("demolish: refund spilled player=%d items=%d", player_index, refund_spilled)
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

---------------------------------------------------------------------------
-- Phase 5 M2 integration: disband selected units (Nation mode). The bin button on the HUD's units page, or Delete with
-- units and no building selected. Two presses like Demolish; the units are removed, their recruits go back to their
-- home city (labor.disband; the nearest own city when it is gone), nothing else is refunded. The Commander stays.
---------------------------------------------------------------------------
local function nation()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end
demolish.nation = nation

-- Own disbandable units of the selection (unit numbers ascending), and how many Commanders were left out.
local function disband_list(player_index)
  local force = selection.force_name and selection.force_name(player_index)
  local out, kept = {}, 0
  for _, e in ipairs(selection.get(player_index)) do
    local rec = storage.units[e.unit_number]
    if rec and (not force or rec.force == force) then
      if rec.kind == "commander" then kept = kept + 1 else out[#out + 1] = e.unit_number end
    end
  end
  table.sort(out)
  return out, kept
end

--- Press of the Disband button (or Delete with units selected). Returns "none" | "blocked" | "armed" | "done", n.
--- QA log lines: "disband: armed|done player=N units=M ...".
function demolish.disband(player_index)
  if not nation() then return "none", 0 end
  local list, kept = disband_list(player_index)
  if #list == 0 then
    if kept > 0 then
      say(player_index, {"rts.disband-commander"})
      return "blocked", 0
    end
    return "none", 0
  end
  local p = util.pstorage(player_index)
  local key = table.concat(list, ",")
  local st = p.disband
  if not (st and st.key == key and game.tick - st.tick <= demolish.CONFIRM_TICKS) then
    p.disband = {key = key, tick = game.tick}
    say(player_index, {"rts.disband-armed", #list})
    util.log("disband: armed player=%d units=%d", player_index, #list)
    selection.notify_hud(player_index)
    return "armed", #list
  end
  p.disband = nil
  local labor = package.loaded["__" .. script.mod_name .. "__/scripts/labor.lua"] or package.loaded["scripts.labor"]
  local n, back = 0, 0
  for _, un in ipairs(list) do
    local rec = storage.units[un]
    if rec and rec.entity.valid then
      local before = 0
      if labor and labor.home_of then
        local _, r = labor.home_of(un)
        before = r or 0
      end
      local ok = labor and labor.disband and labor.disband(un)
      if not ok and rec.entity.valid then
        rec.entity.destroy({raise_destroy = true})
        ok = true
      end
      if ok then
        n = n + 1
        back = back + before
      end
    end
  end
  if kept > 0 then say(player_index, {"rts.disband-commander"}) end
  say(player_index, {"rts.disband-done", n, math.floor(back + 0.5)})
  util.log("disband: done player=%d units=%d recruits back %.1f", player_index, n, back)
  selection.notify_hud(player_index)
  return "done", n
end

--- True while a Disband press waits for its second press (the HUD shows the bin armed).
function demolish.disband_armed(player_index)
  local st = util.pstorage(player_index).disband
  return st ~= nil and game.tick - st.tick <= demolish.CONFIRM_TICKS
end

events.on("rts-demolish", function(e)
  if not real_player(e.player_index) then return end
  local result = demolish.request(e.player_index)
  -- Phase 5 M2 integration: Delete with units (and no building) selected disbands them in Nation mode
  if result == "none" and nation() and selection.count(e.player_index) > 0 then demolish.disband(e.player_index) end
end)

return demolish
