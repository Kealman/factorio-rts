-- Phase 5 M2 world functional probe (test copy only; tools/autotest-run.sh with EXTRA_LUA=tools/probes/world2_autotest.lua
-- and a Nation match table, STOP_ON='world2 autotest summary'). Once the world's fill is done it checks what the seed
-- matrix does not: the Geology gate on uranium (an extractor ghost of rts-player over uranium is refused, accepted
-- after Geology), city-state garrison growth (4 + 1 per 10 minutes) and its magazines, region names for alerts, the
-- strategic label API (a route label with a line; remove), the region record (owner share of the home region, bbox,
-- sites), the scarcity record, and the per-force label counts after a refresh. Log lines "[rts] world2 autotest ...",
-- checks "[rts] autotest check w2_<name>: PASS|FAIL", the last line "[rts] world2 autotest summary P/T".
local events = require("scripts.events")
local util = require("scripts.util")
local world = require("scripts.world")
local strategic = require("scripts.strategic")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local match = require("scripts.match")
local ai = require("scripts.ai.init")

local function S()
  storage.w2test = storage.w2test or {pass = 0, fail = 0, step = 1}
  return storage.w2test
end

local function check(name, ok, fmt, ...)
  local st = S()
  if ok then st.pass = st.pass + 1 else st.fail = st.fail + 1 end
  util.log("autotest check w2_%s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function uranium_spot()
  for _, s in ipairs(world.sites("uranium")) do return s.position end
end

-- A player's ghost placement through world.geology_check alone (territory.lua refuses an extractor off own land on
-- its own; uranium lies on neutral or city-state land). Returns "kept" or "refused".
local function geology(surface, force, name, pos)
  local ghost = surface.create_entity({name = "entity-ghost", inner_name = name, position = pos, force = force})
  if not ghost then return "no ghost" end
  local ok = world.geology_check(ghost, {name = defines.events.on_built_entity, player_index = 0, entity = ghost})
  local valid = ghost.valid
  if valid then ghost.destroy() end
  return (ok and valid) and "kept" or "refused"
end

events.on_nth_tick(60, function(e)
  local st = S()
  local W = storage.world
  local m = storage.match
  if st.done or not (m and m.phase == "running" and W and W.plan) then return end
  if not st.stopped then
    st.stopped = true
    for _, f in ipairs(match.ai_forces()) do ai.stop_force(f) end
    local surface = game.surfaces[W.surface]
    surface.request_to_generate_chunks({0, 0}, math.ceil(W.size / 64))
    surface.force_generate_chunk_requests()
    return
  end
  if not world.ready() then return end
  local surface = game.surfaces[W.surface]
  local force = game.forces[match.PLAYER]
  if st.step == 1 then
    territory.flush()
    -- Geology gate
    local u = uranium_spot()
    local before = force.technologies["rts-geology"].researched
    local r1 = u and geology(surface, force, "rts-extractor", {x = u.x + 0.5, y = u.y + 0.5})
    force.technologies["rts-geology"].researched = true
    local r2 = u and geology(surface, force, "rts-extractor", {x = u.x + 0.5, y = u.y + 0.5})
    force.technologies["rts-geology"].researched = before
    local away = match.home(match.PLAYER)
    local r3 = geology(surface, force, "rts-extractor", {x = away.x + 30.5, y = away.y + 30.5})
    check("geology_gate", u ~= nil and r1 == "refused" and r2 == "kept" and r3 == "kept",
      "uranium at %s: without Geology %s, with Geology %s; away from uranium without Geology %s",
      u and util.pos_str(u) or "-", tostring(r1), tostring(r2), tostring(r3))
    -- garrison growth: pretend the first city-state was founded 21 minutes ago
    local rec = world.city_states()[1]
    st.cs = rec and rec.city_id
    if rec then
      st.added0 = rec.added or 0
      rec.founded = game.tick - 21 * 3600
      local c = cities.get(rec.city_id)
      local net = c and c.entity.logistic_network
      if net then net.remove_item({name = "firearm-magazine", count = 1000}) end
    end
    st.step = 2
  elseif st.step == 2 then
    st.wait = (st.wait or 0) + 1
    if st.wait < 22 then return end -- two garrison steps (600 ticks each)
    local rec
    for _, r in ipairs(world.city_states()) do if r.city_id == st.cs then rec = r end end
    local c = rec and cities.get(rec.city_id)
    local net = c and c.entity.logistic_network
    local mags = net and net.get_item_count("firearm-magazine") or 0
    local live = 0
    for _, t in ipairs(rec and rec.turrets or {}) do if t.valid and t.force.name == world.NEUTRAL then live = live + 1 end end
    check("garrison_growth", rec ~= nil and (rec.added or 0) == st.added0 + 2 and live == rec.added and mags >= world.CS.ammo_keep / 2,
      "%s: turrets added %d -> %d (want +2 after 21 min), %d live, magazines in its network %d", rec and rec.label or "-",
      st.added0 or -1, rec and rec.added or -1, live, mags)
    -- city-state record: archetype, no capital, no nation, title
    check("city_state_record", c ~= nil and c.archetype == "city_state" and not c.capital and c.force == world.NEUTRAL
      and storage.nations[world.NEUTRAL] == nil and c.title ~= nil and c.radius == cities.radius_of(world.CS.tier, false),
      "city %s archetype %s capital %s force %s nation %s radius %s", tostring(c and c.id), tostring(c and c.archetype),
      tostring(c and c.capital), tostring(c and c.force), tostring(storage.nations[world.NEUTRAL]), tostring(c and c.radius))
    -- region names for alerts, region records
    local home = match.home(match.PLAYER)
    local reg = world.region_at(home)
    local share = reg and reg.owner_share or {}
    check("region_record", reg ~= nil and reg.name ~= nil and world.place_name(home) ~= nil and reg.bbox ~= nil
      and (share[match.PLAYER] or 0) > 0 and #reg.sites >= 0 and table_size(reg.resources) >= 4,
      "%s (%s): owner share %s, bbox %s, %d sites, resources %s", reg and reg.label or "-", reg and reg.kind or "-",
      serpent.line(share), serpent.line(reg and reg.bbox), reg and #reg.sites or 0, serpent.line(reg and reg.resources))
    local sc = world.scarcity()
    local sc_ok = true
    for _, f in ipairs(match.forces()) do
      if not (sc[f] and sc[f].home_specialty and #sc[f].lacks >= 1) then sc_ok = false end
    end
    check("scarcity_record", sc_ok, "%s", serpent.line(sc))
    -- strategic labels: a route label (line + text), counted for its force, removed again
    local before_cnt = strategic.counts(match.PLAYER).labels
    local key = strategic.label("route", home, "test route", {forces = {match.PLAYER}, to = {x = 0, y = 0},
      color = {0.4, 0.9, 1}})
    local mid = strategic.counts(match.PLAYER).labels
    strategic.remove(key)
    local after = strategic.counts(match.PLAYER).labels
    check("label_api", key ~= nil and mid == before_cnt + 2 and after == before_cnt, "labels %d -> %d -> %d (key %s)",
      before_cnt, mid, after, tostring(key))
    local n = strategic.refresh_all()
    local cnt = strategic.counts(match.PLAYER)
    check("refresh", n > 0 and cnt.regions == #world.regions() and cnt.cities == table_size(storage.cities or {}),
      "refresh_all %d objects; rts-player %s; %d regions, %d cities", n, serpent.line(cnt), #world.regions(),
      table_size(storage.cities or {}))
    st.done = true
    util.log("world2 autotest summary %d/%d%s", st.pass, st.pass + st.fail,
      st.fail == 0 and " (all passed)" or string.format(" (%d FAILED)", st.fail))
  end
end)
