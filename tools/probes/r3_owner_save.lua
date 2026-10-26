-- Release 0.1.2 r3-orders: the owner's 0.1.1 save with this tree (test copy only; see tools/saveload-check.sh for the
-- --start-server call). The module is required last by a copy of the mod; 5 s after the load it takes the first own
-- factory and barracks that hold no recipe, orders 1 craft of the first recipe they can make and logs
--   [rts] r3 owner <check>: PASS|FAIL ...
-- (queue_factory, queue_barracks), plus a "r3 owner loaded" line with the counts so the run shows what the save has.
-- With CLEAR_CHECK the clear order is tried too (see scripts/r3_owner_save.lua tail, added with #24).
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local production = require("scripts.production")

local S = {}

local function pick(kind, recipes)
  for _, force in ipairs({util.PLAYER_FORCE}) do
    for _, rec in buildings.for_force(force, kind) do
      if rec.entity.valid and not rec.entity.get_recipe() then
        for _, r in ipairs(recipes) do
          if rec.entity.force.recipes[r] and rec.entity.force.recipes[r].enabled then return rec, r end
        end
      end
    end
  end
end

events.on_nth_tick(60, function()
  if S.done or not storage.match then return end
  S.n = (S.n or 0) + 1
  if S.n == 5 then
    local f, fr = pick("factory", {"rts-extractor", "rts-stockpile", "iron-gear-wheel"})
    local b, br = pick("barracks", {"rts-walker-kit"})
    S.f, S.b = f and f.entity.unit_number, b and b.entity.unit_number
    util.log("r3 owner loaded: tick %d, match phase %s, factory %s (%s), barracks %s (%s)", game.tick,
      tostring(storage.match.phase), tostring(S.f), tostring(fr), tostring(S.b), tostring(br))
    S.fr, S.br = fr, br
    S.fm = f and (f.made or 0)
    S.bs = b and (b.spawned or 0)
    if f then production.queue_recipe(S.f, fr, 1) end
    if b then production.queue_recipe(S.b, br, 1) end
  elseif S.n > 5 then
    local f = S.f and buildings.get(S.f)
    local b = S.b and buildings.get(S.b)
    if f and not S.fd and not f.queue then
      S.fd = true
      util.log("r3 owner queue_factory: %s the order finished, made %d, recipe %s",
        ((f.made or 0) - S.fm == 1) and "PASS" or "FAIL", (f.made or 0) - S.fm,
        tostring(f.entity.get_recipe() and f.entity.get_recipe().name))
    end
    if b and not S.bd and not b.queue then
      S.bd = true
      util.log("r3 owner queue_barracks: %s spawned %d", ((b.spawned or 0) - S.bs == 1) and "PASS" or "FAIL",
        (b.spawned or 0) - S.bs)
    end
    if (S.fd or not S.f) and (S.bd or not S.b) and not S.done then
      S.done = true
      util.log("r3 owner done")
    end
  end
end)
