-- Wave C headless probe (test copy only: tools/autotest-run.sh EXTRA_LUA=tools/probes/wavec_headless.lua).
-- 1. Natural hub: rts-player is taken from its AI commander and gets a Commander and one rts-hub item in its CC pool; a
--    hub ghost goes next to its natural iron patch (50-76 tiles out, beyond the CC's 40-tile robot reach) and the
--    Commander walks there. PASS when the Commander's robots build it (field supply, scripts/commander.lua) within 90 s
--    and the hub's logistic network is not the CC's.
-- 2. Cargo between the two networks: the CC exports iron above 0, a hauler gets the route CC (pickup) -> natural hub
--    (drop-off). PASS when the hub's network holds the delivered iron (its default Keep asks for 50) within 90 s.
-- 3. Concede: then match.concede("rts-player") must end the match at once with an AI as the winner and a defeat for
--    rts-player. Log lines "[rts] wavec probe ...".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local logistics = require("scripts.logistics")
local commander = require("scripts.commander")

local F = util.PLAYER_FORCE

local function natural_site(home)
  for _, p in ipairs((storage.mapgen and storage.mapgen.patches) or {}) do
    if p.kind == "natural" and p.force == F and p.name == "iron-ore" then
      -- 7 tiles from the patch centre towards the CC: next to the ore, not on it
      local dx, dy = home.x - p.center.x, home.y - p.center.y
      local d = math.sqrt(dx * dx + dy * dy)
      return {x = math.floor(p.center.x + dx / d * 9) + 0.0, y = math.floor(p.center.y + dy / d * 9) + 0.0}, p
    end
  end
end

events.on_nth_tick(60, function()
  local m = storage.match
  if not (m and m.tick_started) then return end
  local P = storage.wavec_probe
  if not P then
    P = {}
    storage.wavec_probe = P
  end
  if P.done then return end
  if not P.started then
    if m.phase ~= "running" or game.tick - m.tick_started < 120 then return end
    P.started = game.tick
    ai.stop_force(F)
    commander.enable(F)
    local hero = commander.spawn_now(F)
    local cc = buildings.main_cc(F)
    local home = match.home(F)
    local site, patch = natural_site(home)
    economy.give(F, "rts-hub", 1)
    local surface = cc.entity.surface
    for _, o in pairs(surface.find_entities_filtered({area = {{site.x - 4, site.y - 4}, {site.x + 4, site.y + 4}},
                                                       type = {"tree", "simple-entity"}})) do o.destroy() end
    local g = surface.create_entity({name = "entity-ghost", inner_name = "rts-hub", position = site, force = F})
    P.site = site
    if hero then hero.autopilot_destination = {x = site.x - 4, y = site.y} end
    util.log("wavec probe: hub ghost %s at %s, %.0f tiles from the CC (natural iron centre %s, %.0f tiles); CC "
      .. "construction radius %d; Commander %s walks there", tostring(g ~= nil), util.pos_str(site),
      util.distance(site, home), util.pos_str(patch.center), util.distance(patch.center, home),
      cc.entity.logistic_cell.construction_radius, hero and ("#" .. hero.unit_number) or "missing")
    return
  end
  if not P.hub_done then
    local hub
    for _, rec in buildings.for_force(F, "hub") do hub = rec.entity end
    local waited = (game.tick - P.started) / 60
    if hub then
      local cc = buildings.main_cc(F)
      local hn, cn = hub.logistic_network, cc.entity.logistic_network
      local own = hn and cn and hn.network_id ~= cn.network_id
      util.log("wavec probe: natural hub %s: built %.0f s after the ghost at %s; hub network #%s, CC network #%s",
        own and "PASS" or "FAIL", waited, util.pos_str(hub.position), hn and hn.network_id or "-",
        cn and cn.network_id or "-")
      P.hub_done = true
      P.hub_un, P.cc_un = hub.unit_number, cc.entity.unit_number
      logistics.set_policy(P.cc_un, "export_above", "iron-plate", 0)
      local h = logistics.spawn_hauler(cc.entity.surface, buildings.default_exit(cc), F, P.cc_un)
      if h then
        P.hauler = h.unit_number
        logistics.set_pickup(h.unit_number, P.cc_un)
        logistics.set_dropoff(h.unit_number, P.hub_un)
      end
      P.cargo_from = game.tick
    elseif waited >= 90 then
      util.log("wavec probe: natural hub FAIL: not built after %.0f s", waited)
      P.hub_done = true
    end
    return
  end
  if not P.cargo_done then
    -- (game.get_entity_by_unit_number does not find roboports: no get-by-unit-number flag)
    local net = logistics.hub_network(P.hub_un)
    local iron = net and net.get_item_count("iron-plate") or 0
    local waited = (game.tick - P.cargo_from) / 60
    local h = logistics.hauler(P.hauler)
    local delivered = h and h.delivered and h.delivered["iron-plate"] or 0
    if (iron > 0 and iron >= delivered) or waited >= 90 then
      util.log("wavec probe: cargo %s: hub network holds %d iron after %.0f s; hauler trips %s, delivered %d iron",
        iron > 0 and iron >= delivered and "PASS" or "FAIL", iron, waited, h and h.trips or "-", delivered)
      P.cargo_done = true
    end
    return
  end
  local ended = match.concede(F, "probe")
  local r = match.result(F)
  local ok = ended and m.phase == "ended" and r == "defeat" and m.winner ~= F and m.conceded == F
  util.log("wavec probe: concede %s: ended=%s phase=%s winner=%s result for %s=%s; a second concede returns %s",
    ok and "PASS" or "FAIL", tostring(ended), tostring(m.phase), tostring(m.winner), F, tostring(r),
    tostring(match.concede(F, "probe again")))
  P.done = true
end)
