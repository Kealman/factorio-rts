-- Release 0.1.2 r3-orders headless probe (test copy only):
--   EXTRA_LUA=tools/probes/r3_orders_headless.lua STOP_ON='r3 orders summary' \
--     tools/autotest-run.sh r3o-orders '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 400
-- Skirmish match, the player's AI stopped, a factory and a barracks placed by script next to the CC with a stocked
-- network. Log lines "[rts] r3 orders <check>: PASS|FAIL ..." and "[rts] r3 orders summary <passed>/<total>".
--   queue1      factory: queue_recipe(extractor, 1): exactly 1 extractor reaches the network, the machine stops
--               (no recipe, no queue), and makes nothing more in the next 15 s
--   queue5      factory: 5 crafts -> 5 extractors, status.queue counts down, then it stops
--   affordable  production.affordable (Ctrl+click) = crafts the limiting ingredient pays for
--   ctrl        a Ctrl-sized order runs to the end
--   endless     set_recipe (the Endless toggle / the AI) drops the queue and keeps making past the ordered count
--   auto        a machine in Auto: the order overrides it (mode fixed), the end hands it back to Auto
--   unqueue     removing crafts from the order; at zero the machine stops
--   barracks    1 kit -> exactly 1 unit and the barracks stops; 5 kits -> 5 units
--   clear_*     #24: 4 walkers clear a 20-tree patch (entity-list call); a right click on a tree and a Shift drag over a
--               patch (handle_reverse_area); a rock pays stone; a hub ghost over 16 trees marks them and gets built
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local match = require("scripts.match")
local units = require("scripts.units")

local F = util.PLAYER_FORCE
local S = {pass = 0, fail = 0, step = 0}

local function check(name, ok, fmt, ...)
  if ok then S.pass = S.pass + 1 else S.fail = S.fail + 1 end
  util.log("r3 orders %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function place(surface, name, want)
  local pos = surface.find_non_colliding_position(name, want, 14, 1, true)
  for _, o in pairs(surface.find_entities_filtered({area = {{pos.x - 3, pos.y - 3}, {pos.x + 3, pos.y + 3}},
                                                     type = {"tree", "simple-entity", "cliff"}})) do o.destroy() end
  return surface.create_entity({name = name, position = pos, force = F, raise_built = true})
end

local function moved(rec) return rec.moved or 0 end -- items the factory handed to the network

local function stock(item)
  local net = economy.network(F)
  return net and net.get_item_count(item) or 0
end

local function stock_up()
  for _, item in ipairs({"iron-plate", "copper-plate", "stone-brick", "steel-plate", "coal", "stone"}) do
    local have = stock(item)
    if have < 3000 then economy.give(F, item, 3000 - have) end
  end
  for _, item in ipairs({"electronic-circuit", "iron-gear-wheel"}) do
    local have = stock(item)
    if have < 300 then economy.give(F, item, 300 - have) end
  end
end

local function ingredients(recipe)
  local t = {}
  for _, ing in ipairs(prototypes.recipe[recipe].ingredients) do t[#t + 1] = ing.name .. " " .. ing.amount end
  return table.concat(t, ", ")
end

local function idle(rec) return rec.entity.get_recipe() == nil and rec.queue == nil end
local function recipe_name(e) local r = e.get_recipe() return r and r.name or "none" end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
local WAIT = 90 * 60

step(function(s)
  ai.stop_force(F)
  storage.match.waves_off, storage.match.enemy_next_wave = true, nil -- no waves: units standing still get drawn off by enemies
  storage.debug.qa_reset_checked = true -- the autotest's own qa-reset stage would tear the match down
  local surface = match.surface()
  local home = match.home(F)
  stock_up()
  local f = place(surface, "rts-factory", {x = home.x - 10.5, y = home.y + 10.5})
  local b = place(surface, "rts-barracks", {x = home.x + 10.5, y = home.y + 10.5})
  s.f, s.b = f and f.unit_number, b and b.unit_number
  util.log("r3 orders: factory #%s barracks #%s; extractor = %s; walker kit = %s", tostring(s.f), tostring(s.b),
    ingredients("rts-extractor"), ingredients("rts-walker-kit"))
  return true
end)

step(function(s, tick) -- queue1
  if not s.q1 then
    local rec = buildings.get(s.f)
    s.q1 = {from = tick, items = moved(rec), made = rec.made or 0}
    check("queue1_order", production.queue_recipe(s.f, "rts-extractor", 1) and rec.queue.remaining == 1,
      "queued, recipe %s", recipe_name(rec.entity))
  end
  local rec = buildings.get(s.f)
  if idle(rec) then s.q1.done = tick s.q1.settle = tick return true end
  if tick - s.q1.from > WAIT then
    check("queue1", false, "not finished after 90 s (recipe %s)", recipe_name(rec.entity))
    s.q1.settle = tick
    return true
  end
end)

step(function(s, tick) -- queue1: stays stopped
  if tick - s.q1.settle < 15 * 60 then return end
  local rec = buildings.get(s.f)
  local made = (rec.made or 0) - s.q1.made
  local got = moved(rec) - s.q1.items
  check("queue1", s.q1.done and idle(rec) and made == 1 and got == 1,
    "finished in %.1f s, made %d, network +%d extractors, recipe %s after 15 s", ((s.q1.done or tick) - s.q1.from) / 60,
    made, got, recipe_name(rec.entity))
  return true
end)

step(function(s, tick) -- queue5
  if not s.q5 then
    local rec = buildings.get(s.f)
    s.q5 = {from = tick, items = moved(rec), made = rec.made or 0, seen = {}}
    check("queue5_order", production.queue_recipe(s.f, "rts-extractor", 5), "queued 5")
  end
  local rec = buildings.get(s.f)
  local st = production.status(s.f)
  if st.queue then s.q5.seen[st.queue.remaining] = true end
  if idle(rec) then
    local made = (rec.made or 0) - s.q5.made
    local got = moved(rec) - s.q5.items
    local n = 0
    for _ in pairs(s.q5.seen) do n = n + 1 end
    check("queue5", made == 5 and got == 5 and n >= 3, "made %d, network +%d, %d distinct remaining values, %.1f s",
      made, got, n, (tick - s.q5.from) / 60)
    return true
  end
  if tick - s.q5.from > 3 * WAIT then
    check("queue5", false, "not finished (made %d)", (rec.made or 0) - s.q5.made)
    return true
  end
end)

step(function(s) -- affordable (Ctrl): cut the network to a known stock; the first ingredient pays for 4 crafts
  local proto = prototypes.recipe["rts-extractor"]
  local first = true
  for _, ing in ipairs(proto.ingredients) do
    local have = stock(ing.name)
    local want = (first and 4 or 40) * ing.amount + (ing.amount > 1 and 1 or 0)
    if have > want then economy.take(F, ing.name, have - want) end
    first = false
  end
  S.afford = production.affordable(s.f, "rts-extractor")
  check("affordable", S.afford == 4, "Ctrl count %d (4 expected)", S.afford)
  return true
end)

step(function(s, tick) -- ctrl
  if not s.ct then
    local rec = buildings.get(s.f)
    s.ct = {from = tick, made = rec.made or 0}
    production.queue_recipe(s.f, "rts-extractor", S.afford)
  end
  local rec = buildings.get(s.f)
  if idle(rec) then
    local made = (rec.made or 0) - s.ct.made
    check("ctrl", made == S.afford, "made %d of %d ordered, %.1f s", made, S.afford, (tick - s.ct.from) / 60)
    stock_up()
    return true
  end
  if tick - s.ct.from > 4 * WAIT then
    check("ctrl", false, "not finished (made %d)", (rec.made or 0) - s.ct.made)
    stock_up()
    return true
  end
end)

step(function(s, tick) -- endless drops the queue and goes on
  if not s.en then
    local rec = buildings.get(s.f)
    production.queue_recipe(s.f, "rts-extractor", 2)
    production.set_recipe(s.f, "rts-extractor")
    s.en = {from = tick, made = rec.made or 0, dropped = rec.queue == nil}
  end
  local rec = buildings.get(s.f)
  if (rec.made or 0) - s.en.made >= 4 then
    check("endless", s.en.dropped and recipe_name(rec.entity) == "rts-extractor" and rec.queue == nil,
      "queue dropped %s, made %d (> 2 ordered), recipe %s", tostring(s.en.dropped), (rec.made or 0) - s.en.made,
      recipe_name(rec.entity))
    production.set_recipe(s.f, nil)
    return true
  end
  if tick - s.en.from > 3 * WAIT then
    check("endless", false, "made only %d", (rec.made or 0) - s.en.made)
    production.set_recipe(s.f, nil)
    return true
  end
end)

step(function(s, tick) -- auto: the order overrides Auto
  local rec = buildings.get(s.f)
  production.set_auto(rec, true)
  check("auto_before", production.is_auto(rec), "auto on")
  production.queue_recipe(s.f, "rts-extractor", 1)
  check("auto_override", not production.is_auto(rec) and rec.queue ~= nil and rec.queue.restore_auto == true,
    "mode %s during the order", tostring(rec.recipe_mode))
  s.au = {from = tick}
  return true
end)

step(function(s, tick) -- ... and the end gives it back
  local rec = buildings.get(s.f)
  if rec.queue == nil then
    check("auto_back", production.is_auto(rec), "order done after %.1f s, mode %s", (tick - s.au.from) / 60,
      tostring(rec.recipe_mode))
    production.set_auto(rec, false)
    production.set_recipe(s.f, nil)
    return true
  end
  if tick - s.au.from > WAIT then check("auto_back", false, "order not done") return true end
end)

step(function(s) -- unqueue
  local rec = buildings.get(s.f)
  production.queue_recipe(s.f, "rts-extractor", 10)
  local left = production.unqueue(s.f, 1)
  local left5 = production.unqueue(s.f, 5)
  local ended = production.unqueue(s.f, 99)
  check("unqueue", left == 9 and left5 == 4 and idle(rec), "left %s, %s, then %s; idle %s", tostring(left),
    tostring(left5), tostring(ended), tostring(idle(rec)))
  return true
end)

local function barracks_step(key, count)
  return function(s, tick)
    if not s[key] then
      for _, rec in units.for_force(F) do rec.entity.destroy() end -- room under the supply cap
      local rec = buildings.get(s.b)
      s[key] = {from = tick, spawned = rec.spawned or 0}
      production.queue_recipe(s.b, "rts-walker-kit", count)
    end
    local rec = buildings.get(s.b)
    local k = s[key]
    if idle(rec) then
      k.settle = k.settle or tick
      if tick - k.settle >= 10 * 60 then
        local n = (rec.spawned or 0) - k.spawned
        check("barracks" .. count, n == count, "spawned %d unit(s), barracks idle, %.1f s", n, (tick - k.from) / 60)
        return true
      end
    elseif tick - k.from > 6 * WAIT then
      check("barracks" .. count, false, "not finished (spawned %d)", (rec.spawned or 0) - k.spawned)
      return true
    end
  end
end
step(barracks_step("k1", 1))
step(barracks_step("k5", 5))

---------------------------------------------------------------------------
-- #24 clear orders
---------------------------------------------------------------------------
local orders = require("scripts.orders")
local selection = require("scripts.selection")

local function tree_name()
  local best
  for name, proto in pairs(prototypes.entity) do
    if proto.type == "tree" and (not best or name < best) then best = name end
  end
  return best
end

local function plant(surface, center, n, name)
  local list = {}
  local side = math.ceil(math.sqrt(n))
  for i = 0, n - 1 do
    local pos = {x = center.x + (i % side) * 1.6, y = center.y + math.floor(i / side) * 1.6}
    local t = surface.create_entity({name = name, position = pos})
    if t then list[#list + 1] = t end
  end
  return list
end

local function wipe(surface, c, r)
  for _, o in pairs(surface.find_entities_filtered({area = {{c.x - r, c.y - r}, {c.x + r, c.y + r}},
                                                     type = {"tree", "simple-entity", "cliff"}})) do o.destroy() end
end

local function alive(list)
  local n = 0
  for _, t in ipairs(list) do if t.valid then n = n + 1 end end
  return n
end

local function patch_center()
  local home = match.home(F)
  return {x = home.x + 14, y = home.y - 30}
end

step(function(s, tick) -- clear a 20-tree patch with 4 walkers (an entity-list call, the AI's way)
  if not s.cl then
    local surface = match.surface()
    local c = patch_center()
    wipe(surface, c, 14)
    local trees = plant(surface, c, 20, tree_name())
    local walkers = {}
    for i = 1, 4 do
      walkers[#walkers + 1] = units.spawn("rts-walker", {x = c.x - 8, y = c.y + i}, F, "walker", surface)
    end
    s.cl = {from = tick, trees = trees, n = #trees}
    local n = orders.clear(walkers, trees)
    local neutral = true
    for _, t in ipairs(trees) do if t.force.name ~= "neutral" then neutral = false end end
    check("clear_order", n == 4 and #trees == 20 and neutral, "%d walkers took the order for %d trees (all neutral %s)",
      n, #trees, tostring(neutral))
  end
  if alive(s.cl.trees) == 0 then
    check("clear_patch", (tick - s.cl.from) / 60 <= 25, "20 trees gone in %.1f s", (tick - s.cl.from) / 60)
    return true
  end
  if tick - s.cl.from > 90 * 60 then
    check("clear_patch", false, "%d of %d trees left after 90 s", alive(s.cl.trees), s.cl.n)
    return true
  end
end)

step(function(s, tick) -- the right-click path: a click on a tree, then a Shift drag over a patch
  if not s.rc then
    local surface = match.surface()
    local c = patch_center()
    wipe(surface, c, 14)
    local one = plant(surface, c, 1, tree_name())
    local w = units.spawn("rts-walker", {x = c.x - 6, y = c.y}, F, "walker", surface)
    selection.set(0, {w})
    local p = one[1].position
    local order, n = orders.handle_reverse_area(0, one, {left_top = p, right_bottom = p}, false)
    s.rc = {from = tick, one = one, w = w}
    check("clear_rightclick", order == "clear" and n == 1, "right click on a tree -> %s n=%s", tostring(order), tostring(n))
  end
  if not s.rc.box then
    if alive(s.rc.one) == 0 then
      local c = patch_center()
      s.rc.trees = plant(match.surface(), c, 9, tree_name())
      local area = {left_top = {x = c.x - 2, y = c.y - 2}, right_bottom = {x = c.x + 8, y = c.y + 8}}
      local order, n = orders.handle_reverse_area(0, {}, area, true)
      s.rc.box = tick
      check("clear_box", order == "clear" and n == 1, "shift drag over 9 trees -> %s n=%s", tostring(order), tostring(n))
    elseif tick - s.rc.from > 30 * 60 then
      check("clear_rightclick_done", false, "tree still there after 30 s")
      return true
    end
    return
  end
  if alive(s.rc.trees) == 0 then
    check("clear_box_done", true, "9 trees felled by one walker in %.1f s", (tick - s.rc.box) / 60)
    return true
  end
  if tick - s.rc.box > 60 * 60 then
    check("clear_box_done", false, "%d trees left", alive(s.rc.trees))
    return true
  end
end)

step(function(s, tick) -- a rock pays stone to the nearest own stockpile
  if not s.rk then
    local surface = match.surface()
    local c = patch_center()
    wipe(surface, c, 14)
    local name = prototypes.entity["big-rock"] and "big-rock" or "huge-rock"
    local rock = surface.create_entity({name = name, position = c})
    local w = units.spawn("rts-walker", {x = c.x - 6, y = c.y}, F, "walker", surface)
    local function pile()
      local n = 0
      for _, rec in buildings.for_force(F, "stockpile") do n = n + rec.entity.get_item_count("stone") end
      return n
    end
    s.rk = {from = tick, rock = rock, pile = pile, before = pile() + stock("stone")}
    local n = orders.clear({w}, {rock})
    check("rock_order", rock ~= nil and n == 1, "%s, %d walker", name, n)
  end
  if not s.rk.rock.valid then
    local gained = s.rk.pile() + stock("stone") - s.rk.before
    check("rock_stone", gained > 0, "rock felled in %.1f s, +%d stone", (tick - s.rk.from) / 60, gained)
    return true
  end
  if tick - s.rk.from > 60 * 60 then
    check("rock_stone", false, "rock still there")
    return true
  end
end)

step(function(s, tick) -- a hub ghost inside a forest: the ghost marks the trees, robots clear them and build the hub
  if not s.gh then
    local surface = match.surface()
    local home = match.home(F)
    local c = {x = home.x + 4, y = home.y + 22}
    wipe(surface, c, 10)
    economy.give(F, "rts-hub", 1)
    local trees = plant(surface, {x = c.x - 3, y = c.y - 3}, 16, tree_name())
    local ghost = surface.create_entity({name = "entity-ghost", inner_name = "rts-hub", position = c, force = F})
    local n = orders.mark_ghost_site(ghost)
    local marked = 0
    for _, t in ipairs(trees) do
      if t.valid and t.to_be_deconstructed() then marked = marked + 1 end
    end
    s.gh = {from = tick, ghost = ghost, trees = trees, c = c}
    check("ghost_marks", n > 0 and marked == n, "ghost over %d trees marked %d for deconstruction", alive(trees), n)
  end
  local hub
  for _, rec in buildings.for_force(F, "hub") do
    if util.distance(rec.entity.position, s.gh.c) < 3 then hub = rec.entity end
  end
  if hub then
    check("ghost_built", true, "hub built %.1f s after the ghost, %d of 16 trees left", (tick - s.gh.from) / 60,
      alive(s.gh.trees))
    return true
  end
  if tick - s.gh.from > 150 * 60 then
    check("ghost_built", false, "no hub after 150 s, %d trees left, ghost valid %s", alive(s.gh.trees),
      tostring(s.gh.ghost.valid))
    return true
  end
end)

events.on_nth_tick(30, function()
  local m = storage.match
  if not (m and m.tick_started and m.phase == "running") or S.done then return end
  if game.tick - m.tick_started < 180 then return end
  local fn = STEPS[S.step + 1]
  if not fn then
    S.done = true
    util.log("r3 orders summary %d/%d", S.pass, S.pass + S.fail)
    return
  end
  if fn(S, game.tick) then S.step = S.step + 1 end
end)
