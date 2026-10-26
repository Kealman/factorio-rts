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
-- Clear-order checks are appended by scripts/r3_orders_clear.lua when that test module exists (see r3_clear_headless).
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local match = require("scripts.match")

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

local ok_clear, clear_steps = pcall(require, "scripts.r3_orders_clear")
if ok_clear and type(clear_steps) == "table" then
  for _, fn in ipairs(clear_steps) do step(fn) end
end

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
