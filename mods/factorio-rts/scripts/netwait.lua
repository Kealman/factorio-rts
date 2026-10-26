-- 0.1.2 (issue #26): "robots have nothing to build with". A hub or City Center builds only from its own logistic
-- network; a new city's stockpiles start empty, so own ghosts inside its construction area wait while the Commander's
-- field supply stocks its trunk for them. This module finds those ghosts and says so: the hub panel and the city panel
-- show "N ghosts waiting: no <items> in this network" and one alert per centre per ALERT_TICKS names the city.
--
-- Every CHECK_PERIOD ticks, for every hub / City Center of a human player's force (Nation mode; the AI forces are
-- skipped, so AI behaviour is unchanged): the own entity ghosts within the building's construction radius are counted
-- per item their entity needs (the first item of items_to_place_this) when the network holds fewer than one ghost needs.
-- Read-only on the game; it writes only its own storage.
--
-- Owns storage.netwait = {[hub unit number] = {n = ghosts waiting, items = {[item] = ghosts}, tick = last check,
--                                               alert = tick of the last alert}}. Rebuilt lazily; cleared on teardown.
-- QA log line: "netwait: <name> #un: N ghosts wait for <item>, ...".
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local supply = require("scripts.supply")
local logistics = require("scripts.logistics")
local netwaitline = require("scripts.netwaitline")
local cities = require("scripts.cities")

local netwait = {}

netwait.CHECK_PERIOD = 120
netwait.ALERT_TICKS = 5 * 60 * 60
netwait.MAX_GHOSTS = 400 -- ghosts looked at per centre per check

local function S()
  storage.netwait = storage.netwait or {}
  return storage.netwait
end

--- True for a force an AI drives: a real game's opponents (match.ai_forces) and, in autotests, the player force when an
--- AI commander plays it (storage.ai[force]). Only forces a human plays are looked at.
local function is_ai(force_name)
  if storage.ai and storage.ai[force_name] ~= nil then return true end
  for _, f in ipairs(match.ai_forces()) do
    if f == force_name then return true end
  end
  return false
end

netwait.get, netwait.line = netwaitline.get, netwaitline.line

local function check(un, rec)
  local e = rec.entity
  local net = e.logistic_network
  local radius = e.prototype.construction_radius or 0
  local rst = S()
  local r = rst[un] or {n = 0, items = {}}
  rst[un] = r
  r.tick = game.tick
  local waiting, items = 0, {}
  if net and net.valid and radius > 0 then
    local ghosts = e.surface.find_entities_filtered({position = e.position, radius = radius, force = rec.force,
                                                      type = "entity-ghost", limit = netwait.MAX_GHOSTS})
    for _, g in ipairs(ghosts) do
      local proto = g.valid and g.ghost_prototype
      local first = proto and proto.items_to_place_this and proto.items_to_place_this[1]
      if first and net.get_item_count(first.name) < (first.count or 1) then
        waiting = waiting + 1
        items[first.name] = (items[first.name] or 0) + 1
      end
    end
  end
  local was = r.n
  r.n, r.items = waiting, items
  if waiting > 0 then
    if was == 0 then
      local list = {}
      for item, n in pairs(items) do list[#list + 1] = item .. " x" .. n end
      table.sort(list)
      util.log("netwait: #%d (%s) at %s: %d ghosts wait for %s", un, rec.force, util.pos_str(e.position), waiting,
        table.concat(list, ", "))
    end
    if not r.alert or game.tick - r.alert >= netwait.ALERT_TICKS then
      r.alert = game.tick
      local city = cities.of_center(un)
      local name = city and cities.display_name(city) or logistics.hub_name(un)
      supply.alert(rec.force, "robots-idle", "rts-ux.alert-robots-idle", {name}, e.position)
    end
  end
end

events.on_nth_tick(netwait.CHECK_PERIOD, function()
  if not storage.buildings or not (storage.match and storage.match.config and storage.match.config.mode == "nation") then
    return
  end
  local seen = {}
  for un, rec in buildings.all() do
    if (rec.kind == "hub" or rec.kind == "cc") and not is_ai(rec.force) and rec.force ~= "rts-neutral" then
      seen[un] = true
      check(un, rec)
    end
  end
  for un in pairs(S()) do
    if not seen[un] then storage.netwait[un] = nil end
  end
end)

return netwait
