-- r2-econ (Economy 0.1.1, #10) headless check of the stockpile panel colour: a hub with Keep 400 in the Command
-- Center's network whose Keep is 1000, 809 in the network: the hub's count is white with a tooltip naming the
-- network's 1000, the Command Center's count is yellow. Test-only (tools/autotest-run.sh EXTRA_LUA), Skirmish 1v1:
--   SEED=777 EXTRA_LUA=tools/probes/r2e_hubgui_colour.lua STOP_ON='r2e hubgui colour summary' \
--     tools/autotest-run.sh r2e-hubcol '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 200
-- Log: "[rts] r2e hubgui colour check <name>: PASS|FAIL ..." (4 checks), then "r2e hubgui colour summary done".
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local logistics = require("scripts.logistics")
local hubgui = require("scripts.hubgui")
local ITEM = "stone-brick"

local function check(name, ok, fmt, ...)
  util.log("r2e hubgui colour check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

events.on_nth_tick(60, function(e)
  local S = storage.r2e_hubgui or {}
  storage.r2e_hubgui = S
  if S.done or e.tick < 900 then return end
  local cc, cc_un = buildings.main_cc("rts-player")
  if not cc then return end
  if not S.hub then
    local surface = cc.entity.surface
    local want = {x = cc.entity.position.x + 9, y = cc.entity.position.y + 9}
    local pos = surface.find_non_colliding_position(logistics.HUB, want, 12, 1, true) or want
    local hub = surface.create_entity({name = logistics.HUB, position = pos, force = "rts-player", raise_built = true})
    S.hub = hub and hub.unit_number
    util.log("r2e hubgui colour: hub %s at %s", tostring(S.hub), hub and util.pos_str(hub.position) or "-")
    return
  end
  if not S.set then
    logistics.set_policy(S.hub, "keep", ITEM, 400)
    logistics.set_policy(cc_un, "keep", ITEM, 1000)
    local net = logistics.hub_network(S.hub)
    local have = net and net.get_item_count(ITEM) or 0
    if net and have < 809 then net.insert({name = ITEM, count = 809 - have}) end
    S.set = e.tick
    return
  end
  if e.tick - S.set < 120 then return end
  S.done = true
  local entry = logistics.entry_for_hub(S.hub)
  local same = entry ~= nil and logistics.entry_for_hub(cc_un) ~= nil and logistics.entry_for_hub(cc_un).id == entry.id
  local n = entry and entry.network.get_item_count(ITEM) or 0
  local c1, t1 = hubgui.count_colour(entry, logistics.policy(S.hub), ITEM, n)
  local c2, t2 = hubgui.count_colour(entry, logistics.policy(cc_un), ITEM, n)
  check("same_network", same, "hub #%s and CC #%d in network %s (%d hubs)", tostring(S.hub), cc_un,
    tostring(entry and entry.id), entry and #entry.hubs or 0)
  check("hub_own_keep", c1 == "white" and t1 ~= nil, "%d in the network, hub Keep 400, network keep %s -> %s, tooltip %s",
    n, tostring(entry and entry.keep[ITEM]), c1, serpent.line(t1))
  check("cc_own_keep", c2 == "yellow", "%d in the network, CC Keep 1000 -> %s, tooltip %s", n, c2, serpent.line(t2))
  local c3 = hubgui.count_colour(entry, logistics.policy(S.hub), ITEM, 300)
  check("hub_below_own", c3 == "yellow", "300 against the hub's Keep 400 -> %s", c3)
  util.log("r2e hubgui colour summary done")
end)
