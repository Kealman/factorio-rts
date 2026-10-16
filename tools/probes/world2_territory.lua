-- Phase 5 M2 world probe: the Territory victory over claimable cells (docs/PHASE5-M2.md D6, §4 "Territory victory
-- fires at 60 % for 3 minutes"). Test copy only: tools/autotest-run.sh with EXTRA_LUA=tools/probes/world2_territory.lua,
-- STOP_ON='w2terr done' and a 4-nation Nation match table with victory = "territory".
-- 10 s into the match the AIs stop; five forts of rts-ai-1 spread over the map become strong territory sources whose
-- radius grows until rts-ai-1 holds at least 62 % of the claimable cells (world.claimable). It checks that
-- territory.share is the claimable share (territory's per-force count against a recount of the grid), logs the M1
-- all-cells share beside it, and waits for scripts/wars.lua to end the match by a Territory victory 3 minutes later.
-- Log "[rts] w2terr ...", checks "[rts] autotest check w2terr_<name>: PASS|FAIL", stop marker "w2terr done".
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local territory = require("scripts.territory")
local world = require("scripts.world")
local ai = require("scripts.ai.init")

local F = "rts-ai-1"

local function S()
  storage.w2terr = storage.w2terr or {pass = 0, fail = 0}
  return storage.w2terr
end

local function check(name, ok, fmt, ...)
  local st = S()
  if ok then st.pass = st.pass + 1 else st.fail = st.fail + 1 end
  util.log("autotest check w2terr_%s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function finish()
  local st = S()
  if st.done then return end
  st.done = true
  util.log("w2terr summary %d/%d", st.pass, st.pass + st.fail)
  util.log("w2terr done")
end

-- owned claimable cells of a force by a scan of the territory grid
local function recount(fid)
  local T = storage.territory
  local n = 0
  for cy = 0, T.h - 1 do
    local row = T.owner[cy + 1]
    for cx = 0, T.w - 1 do
      if string.byte(row, cx + 1) == fid and world.claimable(cx, cy) then n = n + 1 end
    end
  end
  return n
end

events.on_nth_tick(60, function(e)
  local st = S()
  local m = storage.match
  if st.done or not (m and m.tick_started and storage.world and storage.world.plan) then return end
  if m.phase ~= "running" then return end
  local age = e.tick - m.tick_started
  if not st.setup then
    if age < 600 then return end
    st.setup = true
    for _, f in ipairs(match.ai_forces()) do ai.stop_force(f) end
    local surface = match.surface()
    st.forts = {}
    for _, p in ipairs({{-480, -480}, {480, -480}, {-480, 480}, {480, 480}, {0, 0}}) do
      surface.request_to_generate_chunks(p, 1)
    end
    surface.force_generate_chunk_requests()
    for _, p in ipairs({{-480, -480}, {480, -480}, {-480, 480}, {480, 480}, {0, 0}}) do
      local pos = surface.find_non_colliding_position("rts-fort", p, 80, 1)
      local fort = pos and surface.create_entity({name = "rts-fort", position = pos, force = F, raise_built = true})
      if fort then
        fort.destructible = false
        st.forts[#st.forts + 1] = fort.unit_number
      end
    end
    territory.flush()
    local r, share = 150, 0
    while r <= 1000 do
      for _, un in ipairs(st.forts) do territory.update_source(un, r, 50) end
      territory.flush()
      share = territory.share(F)
      if share >= 0.62 then break end
      r = r + 50
    end
    local T = storage.territory
    local fid = T.fids[F]
    local all_cells = territory.cells(F) / (T.w * T.h)
    local total = world.claimable_count() or 0
    local counted = recount(fid)
    st.from = game.tick
    util.log("w2terr: %d forts of %s at radius %d: claimable share %.1f %% (%d of %d claimable cells), all-cells share "
      .. "%.1f %% (%d of %d cells)", #st.forts, F, r, 100 * share, territory.claimable_cells(F), total, 100 * all_cells,
      territory.cells(F), T.w * T.h)
    check("share_is_claimable", #st.forts == 5 and total > 0 and share >= 0.60
      and math.abs(share - counted / total) < 1e-9 and territory.claimable_cells(F) == counted,
      "share %.4f = %d / %d claimable; recount %d; all-cells share %.4f", share, territory.claimable_cells(F), total,
      counted, all_cells)
    return
  end
  if age > st.from - m.tick_started + 300 * 60 then
    check("territory_victory", false, "no victory 5 minutes after %s reached the share", F)
    finish()
  end
end)

match.on_ended(function(m)
  local st = S()
  if st.done or not st.from then return end
  local dt = (game.tick - st.from) / 60
  check("territory_victory", m.victory ~= nil and m.victory.how == "territory" and m.winners ~= nil
    and m.winners[F] ~= nil and dt >= 180 and dt <= 200, "victory %s %.0f s after %s reached the share",
    serpent.line(m.victory, {comment = false}), dt, F)
  finish()
end)
