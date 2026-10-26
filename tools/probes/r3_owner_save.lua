-- Release 0.1.2 r3-orders: the owner's 0.1.1 save with this tree (test copy only; see tools/saveload-check.sh for the
-- --start-server call). The module is required last by a copy of the mod; 5 s after the load it takes the first own
-- factory and barracks that hold no recipe, orders 1 craft of the first recipe they can make and logs
--   [rts] r3 owner <check>: PASS|FAIL ...
-- (queue_factory, queue_barracks), plus a "r3 owner loaded" line with the counts so the run shows what the save has.
-- Also (#24): a walker is spawned next to the main CC with 3 planted trees and a clear order ("r3 owner clear").
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local units = require("scripts.units")
local orders = require("scripts.orders")

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
    local cc = buildings.main_cc(util.PLAYER_FORCE)
    if cc then
      local surface, p = cc.entity.surface, cc.entity.position
      local name
      for n, proto in pairs(prototypes.entity) do
        if proto.type == "tree" and (not name or n < name) then name = n end
      end
      S.trees = {}
      for i = 1, 3 do
        local pos = surface.find_non_colliding_position("rts-walker", {x = p.x + 12 + i * 2, y = p.y + 12}, 6, 0.5)
        local t = pos and surface.create_entity({name = name, position = pos})
        if t then S.trees[#S.trees + 1] = t end
      end
      local w = units.spawn("rts-walker", {x = p.x + 10, y = p.y + 14}, util.PLAYER_FORCE, "walker", surface)
      S.cleared = w and orders.clear({w}, S.trees) or 0
      S.cstart = game.tick
    end
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
    if S.trees and not S.cd then
      local left = 0
      for _, t in ipairs(S.trees) do if t.valid then left = left + 1 end end
      if left == 0 or game.tick - S.cstart > 60 * 60 then
        S.cd = true
        util.log("r3 owner clear: %s order taken by %d unit(s), %d of %d trees left after %.1f s",
          (left == 0 and S.cleared == 1) and "PASS" or "FAIL", S.cleared or 0, left, #S.trees, (game.tick - S.cstart) / 60)
      end
    end
    if (S.fd or not S.f) and (S.cd or not S.trees) and (S.bd or not S.b) and not S.done then
      S.done = true
      util.log("r3 owner done")
    end
  end
end)
