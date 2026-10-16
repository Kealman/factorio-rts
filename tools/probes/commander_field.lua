-- Commander field construction probe (test copy only: tools/autotest-run.sh EXTRA_LUA=tools/probes/commander_field.lua).
-- Two seconds into the match the probe takes rts-player away from its AI commander, enables a Commander for it, puts
-- one rts-hub and one rts-solar-array into its CC pool, places their ghosts 55 tiles in front of the CC (outside the
-- CC's 40-tile construction radius) and walks the Commander there. PASS: both are built within 90 s, the pool paid for
-- them and the trunk holds nothing but robots afterwards. Log lines "[rts] field probe ...".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local commander = require("scripts.commander")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local match = require("scripts.match")

local F = util.PLAYER_FORCE
local DIST = 55

local function pool(item)
  local n = 0
  for _, net in ipairs(economy.networks(F)) do n = n + net.get_item_count(item) end
  return n
end

events.on_nth_tick(60, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local P = storage.field_probe
  if not P then
    P = {}
    storage.field_probe = P
  end
  if P.done then return end
  local age = game.tick - m.tick_started
  if not P.started then
    if age < 120 then return end
    P.started = game.tick
    ai.stop_force(F)
    commander.enable(F)
    local e = commander.spawn_now(F)
    local home, f, s = match.home(F), match.front(F)
    s = {x = -f.y, y = f.x}
    local site = {x = math.floor(home.x + f.x * DIST) + 0.0, y = math.floor(home.y + f.y * DIST) + 0.0}
    local solar = {x = site.x + s.x * 8 + 0.5, y = site.y + s.y * 8 + 0.5}
    local surface = game.surfaces[m.surface]
    for _, p in ipairs({site, solar}) do
      for _, obstacle in pairs(surface.find_entities_filtered({area = {{p.x - 4, p.y - 4}, {p.x + 4, p.y + 4}},
                                                                type = {"tree", "simple-entity"}})) do
        obstacle.destroy()
      end
    end
    economy.give(F, "rts-hub", 1)
    economy.give(F, "rts-solar-array", 1)
    P.pool_before = {hub = pool("rts-hub"), solar = pool("rts-solar-array")}
    local g1 = surface.create_entity({name = "entity-ghost", inner_name = "rts-hub", position = site, force = F})
    local g2 = surface.create_entity({name = "entity-ghost", inner_name = "rts-solar-array", position = solar, force = F})
    P.site = site
    util.log("field probe: started at tick %d: Commander %s, ghosts hub %s solar %s at %s (%.0f tiles from the CC), pool "
      .. "hub %d solar %d", game.tick, e and ("#" .. e.unit_number) or "missing", tostring(g1 ~= nil), tostring(g2 ~= nil),
      util.pos_str(site), util.distance(site, home), P.pool_before.hub, P.pool_before.solar)
    if e then e.autopilot_destination = {x = site.x - f.x * 6, y = site.y - f.y * 6} end
    return
  end
  local e = commander.entity(F)
  local hub = buildings.count(F, "hub")
  local solar = 0
  for _, rec in buildings.for_force(F) do
    if rec.entity.valid and rec.entity.name == "rts-solar-array" then solar = solar + 1 end
  end
  local waited = (game.tick - P.started) / 60
  if hub >= 1 and solar >= 1 and not P.built then
    P.built = game.tick
    util.log("field probe: hub and solar array built %.0f s after the start (Commander at %s)", waited,
      e and util.pos_str(e.position) or "-")
  end
  if P.built and game.tick - P.built >= 180 then
    local trunk = e and e.get_inventory(defines.inventory.spider_trunk)
    local extra = {}
    for _, it in pairs(trunk and trunk.get_contents() or {}) do
      if it.name ~= "construction-robot" then extra[#extra + 1] = it.name .. " x" .. it.count end
    end
    local paid = pool("rts-hub") == P.pool_before.hub - 1 and pool("rts-solar-array") == P.pool_before.solar - 1
    local ok = #extra == 0 and paid
    util.log("field probe: %s: hub %d solar %d, pool now hub %d solar %d (before %d %d), trunk extras [%s]",
      ok and "PASS" or "FAIL", hub, solar, pool("rts-hub"), pool("rts-solar-array"), P.pool_before.hub,
      P.pool_before.solar, table.concat(extra, " "))
    P.done = true
  elseif waited >= 90 and not P.built then
    util.log("field probe: FAIL: after %.0f s hub %d solar %d, Commander at %s", waited, hub, solar,
      e and util.pos_str(e.position) or "-")
    P.done = true
  end
end)
