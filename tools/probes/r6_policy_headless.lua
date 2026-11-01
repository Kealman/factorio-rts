-- Release 0.1.4 r6-hud headless probe (#46): a hauler route works from an explicit Carry list. Test copy only:
--   EXTRA_LUA=tools/probes/r6_policy_headless.lua tools/autotest-run.sh r6-policy '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' 400
--   (add mode = "nation" for the Nation run)
-- 1. Policy rows: add_policy_row / remove_policy_row (a Keep blocks the removal), no threshold touched.
-- 2. A second hub far from the CC holds 600 petroleum (rts-petroleum; plain "coal" in Skirmish has no such item: the
--    item is rts-petroleum in both modes, a data item). The CC keeps coal only. A manual route hub -> CC:
--    a) no Carry: nothing_reason names why (the pickup exports nothing);
--    b) Carry petroleum, Unload "to Keep" with no Keep for it: reason "dropoff-keeps";
--    c) Unload "everything": the hauler loads and delivers petroleum to the CC network (no Keep for it anywhere).
--    d) Keep 40 at the CC for another run with Unload "to Keep": at most the shortfall is brought.
-- Log lines "[rts] r6 policy <check>: PASS|FAIL ...".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local logistics = require("scripts.logistics")

local F = util.PLAYER_FORCE
local ITEM = "rts-petroleum"

local function check(name, ok, fmt, ...)
  util.log("r6 policy %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

events.on_nth_tick(60, function()
  local m = storage.match
  if not (m and m.tick_started) then return end
  local P = storage.r6_policy
  if not P then
    P = {stage = 0}
    storage.r6_policy = P
  end
  if P.done then return end
  local now = game.tick
  if P.stage == 0 then
    if m.phase ~= "running" or now - m.tick_started < 120 then return end
    ai.stop_force(F)
    local cc = buildings.main_cc(F)
    local surface = cc.entity.surface
    local want = {x = cc.entity.position.x, y = cc.entity.position.y + 100}
    local pos = surface.find_non_colliding_position(logistics.HUB, want, 30, 1, true) or want
    local hub = surface.create_entity({name = logistics.HUB, position = pos, force = F, raise_built = true})
    if not hub then
      check("setup", false, "no hub at %s", util.pos_str(pos))
      P.done = true
      return
    end
    P.hub, P.cc = hub.unit_number, buildings.main_cc(F) and select(2, buildings.main_cc(F))
    local hn, cn = hub.logistic_network, cc.entity.logistic_network
    check("setup", hn ~= nil and cn ~= nil and hn.network_id ~= cn.network_id, "hub #%d at %s, %.0f tiles from the CC, own network",
      hub.unit_number, util.pos_str(hub.position), util.distance(hub.position, cc.entity.position))
    -- 1. rows
    logistics.set_policy(P.cc, "keep", "coal", 50)
    local added = logistics.add_policy_row(P.cc, ITEM)
    local p = logistics.policy(P.cc)
    check("rows_add", added and p.rows[ITEM] == true and p.keep[ITEM] == nil, "row added, no threshold set")
    logistics.set_policy(P.cc, "keep", ITEM, 5)
    check("rows_remove_blocked", logistics.remove_policy_row(P.cc, ITEM) == false and p.rows[ITEM] == true,
      "a Keep blocks the removal")
    logistics.set_policy(P.cc, "keep", ITEM, nil)
    check("rows_remove", logistics.remove_policy_row(P.cc, ITEM) == true and p.rows[ITEM] == nil and p.hidden[ITEM] == true,
      "removed with both fields empty")
    -- 2. route
    hub.logistic_network.insert({name = ITEM, count = 600})
    local h = logistics.spawn_hauler(surface, buildings.default_exit(cc), F, P.cc)
    P.hauler = h.unit_number
    logistics.set_pickup(h.unit_number, P.hub)
    logistics.set_dropoff(h.unit_number, P.cc)
    P.stage, P.t0 = 1, now
    return
  end
  local h = logistics.hauler(P.hauler)
  local cn = logistics.hub_network(P.cc)
  local have = cn and cn.get_item_count(ITEM) or 0
  if P.stage == 1 then -- waiting at the pickup, nothing to load
    if h.state == "waiting" and h.reason == "nothing" then
      local why = logistics.nothing_reason(P.hauler)
      check("reason_no_export", why == "no-export", "no Carry, pickup without Export: reason %s", tostring(why))
      logistics.set_carry(P.hauler, ITEM, 0)
      logistics.set_unload(P.hauler, "keep")
      P.stage, P.t0 = 2, now
    elseif now - P.t0 > 150 * 60 then
      check("reason_no_export", false, "hauler state %s/%s after 150 s", h.state, tostring(h.reason))
      P.done = true
    end
    return
  end
  if P.stage == 2 then -- Unload to Keep, no Keep for it: still nothing
    if now - P.t0 > 4 * 60 then
      local why = logistics.nothing_reason(P.hauler)
      check("reason_dropoff_keeps", why == "dropoff-keeps" and have == 0, "Carry petroleum, Unload to Keep, no Keep: reason %s, CC holds %d",
        tostring(why), have)
      logistics.set_unload(P.hauler, "all")
      P.stage, P.t0 = 3, now
    end
    return
  end
  if P.stage == 3 then -- everything: delivered without any Keep
    if have > 0 and h.state ~= "to_dropoff" then
      check("carry_all", true, "CC network holds %d %s after %.0f s, no Keep for it (hauler %s, delivered %s)", have, ITEM,
        (now - P.t0) / 60, h.state, serpent.line(h.delivered))
      logistics.set_unload(P.hauler, "keep")
      logistics.set_policy(P.cc, "keep", ITEM, have + 40)
      P.base = have
      logistics.hub_network(P.hub).insert({name = ITEM, count = 600}) -- the town makes more
      P.stage, P.t0 = 4, now
    elseif now - P.t0 > 240 * 60 then
      check("carry_all", false, "nothing delivered in 240 s (hauler %s/%s)", h.state, tostring(h.reason))
      P.done = true
    end
    return
  end
  if P.stage == 4 then -- to Keep: at most the 40 short of the Keep
    if have > P.base then
      -- let the unload finish
      if h.state ~= "to_dropoff" then
        check("carry_keep", have <= P.base + 40, "Keep %d: network holds %d (was %d), at most 40 more", P.base + 40, have, P.base)
        P.done = true
      end
    elseif now - P.t0 > 240 * 60 then
      check("carry_keep", false, "no second delivery in 240 s (state %s/%s, CC holds %d)", h.state, tostring(h.reason), have)
      P.done = true
    end
  end
end)
