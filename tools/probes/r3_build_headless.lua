-- Release 0.1.2 r3-build headless probe (#23 select/demolish belts, inserters, poles; #27 cancel ghosts; #25 new
-- pieces). Test copy only:
--   STOP_ON='r3 build probe done' EXTRA_LUA=tools/probes/r3_build_headless.lua tools/autotest-run.sh r3b \
--     '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240
-- On the running match (rts-player AI stopped), selection index 0 (the fake index, force rts-player):
--  1. click-select a belt, an inserter, a pole; two Delete presses each: gone, refund logged, held items moved
--  2. a boxed line of 10 belts: one group, 2 presses, 5 iron plates refunded (10 belts = 10 iron, 50 %)
--  3. a smelter ghost: click select, ONE press cancels it; 10 belt ghosts boxed, one press cancels all
--  4. enemy-force belt and ghost are not selectable (click and box); a Command Center click still selects the CC
--  5. (#25) underground belt, splitter and long-handed inserter select and demolish like the others
-- Log lines "[rts] r3 build probe <name>: PASS|FAIL ...".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local demolish = require("scripts.demolish")
local pieces = require("scripts.pieces")

local F = util.PLAYER_FORCE
local fails = 0

local function check(name, ok, fmt, ...)
  if not ok then fails = fails + 1 end
  util.log("r3 build probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt or "", ...))
end

local function stock(item)
  local n = 0
  for _, rec in buildings.for_force(F, "stockpile") do n = n + rec.entity.get_item_count(item) end
  return n
end

local function click(surface, pos)
  return selection.handle_area(0, {}, {left_top = {x = pos.x - 0.02, y = pos.y - 0.02},
                                       right_bottom = {x = pos.x + 0.02, y = pos.y + 0.02}}, false, surface)
end

local function box(surface, x1, y1, x2, y2)
  return selection.handle_area(0, {}, {left_top = {x = x1, y = y1}, right_bottom = {x = x2, y = y2}}, false, surface)
end

local function two_presses()
  local r1 = demolish.request(0)
  local r2 = demolish.request(0)
  return r1, r2
end

local function make(surface, name, pos, extra)
  local spec = {name = name, position = pos, force = F, raise_built = true}
  for k, v in pairs(extra or {}) do spec[k] = v end
  return surface.create_entity(spec)
end

local function run()
  local cc = buildings.main_cc(F)
  local surface = cc.entity.surface
  local home = cc.entity.position
  -- an empty strip 30 tiles from the CC (clear it first: trees, rocks)
  local bx, by = math.floor(home.x) + 30, math.floor(home.y) + 30
  for _, e in pairs(surface.find_entities_filtered({area = {{bx - 2, by - 8}, {bx + 16, by + 8}}})) do
    if e.valid and e.type ~= "character" and e.force and e.force.name ~= F then e.destroy() end
  end
  local registry0 = buildings.count(F)

  -- 1. single pieces
  local belt = make(surface, "transport-belt", {bx + 0.5, by + 0.5}, {direction = defines.direction.east})
  local ins = make(surface, "fast-inserter", {bx + 3.5, by + 0.5}, {direction = defines.direction.east})
  local pole = make(surface, "medium-electric-pole", {bx + 6.5, by + 0.5})
  check("built", belt and ins and pole, "")
  check("no registry growth", buildings.count(F) == registry0, "%d vs %d", buildings.count(F), registry0)
  for _, name in ipairs({"belt", "inserter", "pole"}) do
    local e = ({belt = belt, inserter = ins, pole = pole})[name]
    local pos = e.position
    if name == "belt" then
      e.get_transport_line(1).insert_at_back({name = "iron-plate", count = 3})
    elseif name == "inserter" then
      e.held_stack.set_stack({name = "iron-plate", count = 1})
    end
    local held = 0
    if name == "belt" then held = e.get_transport_line(1).get_item_count("iron-plate") end
    if name == "inserter" then held = 1 end
    local iron0 = stock("iron-plate")
    click(surface, pos)
    local sel = selection.get_pieces(0)
    check(name .. " click", #sel == 1 and sel[1] == e, "selected %d", #sel)
    local d = pieces.describe(e)
    check(name .. " describe", d.title ~= nil and d.lines[1] ~= nil, "rotatable=%s", tostring(d.rotatable))
    local r1, r2 = two_presses()
    check(name .. " two presses", r1 == "armed" and r2 == "done" and not e.valid, "%s then %s", r1, r2)
    check(name .. " contents/refund", stock("iron-plate") - iron0 >= held + (name == "inserter" and 1 or 0),
      "iron %+d (held %d)", stock("iron-plate") - iron0, held)
    check(name .. " selection cleared", #selection.get_pieces(0) == 0, "")
  end

  -- 2. a boxed line of 10 belts
  local line = {}
  for i = 0, 9 do line[#line + 1] = make(surface, "transport-belt", {bx + 0.5 + i, by + 4.5}, {direction = defines.direction.east}) end
  local iron0 = stock("iron-plate")
  box(surface, bx - 0.5, by + 3.5, bx + 10.5, by + 5.5)
  check("box select 10 belts", #selection.get_pieces(0) == 10, "selected %d", #selection.get_pieces(0))
  local r1, r2 = two_presses()
  local gone = 0
  for _, e in ipairs(line) do if not e.valid then gone = gone + 1 end end
  check("box demolish", r1 == "armed" and r2 == "done" and gone == 10, "%s %s gone=%d", r1, r2, gone)
  check("box refund 5 iron", stock("iron-plate") - iron0 == 5, "iron %+d (want 5)", stock("iron-plate") - iron0)
  -- one lone belt refunds nothing
  local lone = make(surface, "transport-belt", {bx + 0.5, by + 8.5})
  iron0 = stock("iron-plate")
  click(surface, lone.position)
  r1, r2 = two_presses()
  check("lone belt refund 0", r2 == "done" and not lone.valid and stock("iron-plate") == iron0, "iron %+d", stock("iron-plate") - iron0)

  -- 3. ghosts: one press
  local ghost = surface.create_entity({name = "entity-ghost", inner_name = "rts-smelter", position = {bx + 8, by - 5},
                                       force = F, raise_built = true})
  check("ghost made", ghost and ghost.valid, "")
  click(surface, ghost.position)
  local sel = selection.get_pieces(0)
  check("ghost click", #sel == 1 and sel[1] == ghost, "selected %d", #sel)
  r1 = demolish.request(0)
  check("ghost one press", r1 == "done" and not ghost.valid, "%s", r1)
  local gl = {}
  for i = 0, 9 do
    gl[#gl + 1] = surface.create_entity({name = "entity-ghost", inner_name = "transport-belt",
      position = {bx + 0.5 + i, by - 1.5}, force = F, direction = defines.direction.east, raise_built = true})
  end
  box(surface, bx - 0.5, by - 2.5, bx + 10.5, by - 0.5)
  check("ghost box", #selection.get_pieces(0) == 10, "selected %d", #selection.get_pieces(0))
  r1 = demolish.request(0)
  local left = 0
  for _, e in ipairs(gl) do if e.valid then left = left + 1 end end
  check("ghost box cancel", r1 == "done" and left == 0, "%s left=%d", r1, left)

  -- 4. foreign entities are not selectable
  local eb = surface.create_entity({name = "transport-belt", position = {bx + 12.5, by + 0.5}, force = util.ENEMY_FORCE})
  local eg = surface.create_entity({name = "entity-ghost", inner_name = "transport-belt", position = {bx + 12.5, by + 2.5},
                                    force = util.ENEMY_FORCE})
  click(surface, eb.position)
  check("enemy belt click", #selection.get_pieces(0) == 0, "")
  click(surface, eg.position)
  check("enemy ghost click", #selection.get_pieces(0) == 0, "")
  box(surface, bx + 11, by - 1, bx + 14, by + 4)
  check("enemy box", #selection.get_pieces(0) == 0, "")
  eb.destroy()
  eg.destroy()
  -- a building still wins when it is the nearer one
  selection.clear(0)
  click(surface, cc.entity.position)
  check("cc click", select(1, selection.get_building(0)) == cc.entity.unit_number, "")
  selection.clear(0)

  -- 5. #25 pieces
  local names = {"underground-belt", "splitter", "long-handed-inserter"}
  for i, name in ipairs(names) do
    if prototypes.entity[name] then
      local x = bx + 0.5 + (i - 1) * 4
      local e = surface.create_entity({name = name, position = {x, by + 12}, force = F, direction = defines.direction.east,
                                       raise_built = true})
      if e then
        click(surface, e.position)
        local s2 = selection.get_pieces(0)
        check(name .. " click", #s2 == 1, "selected %d", #s2)
        r1, r2 = two_presses()
        check(name .. " demolish", r2 == "done" and not e.valid, "%s %s", r1, r2)
      else
        check(name .. " built", false, "create_entity returned nil")
      end
    end
  end
  -- #25 recipes: enabled for the force, craftable in the factory, refund of a pair
  for _, r in ipairs({"rts-underground-belt", "rts-splitter", "rts-long-inserter"}) do
    local rec = game.forces[F].recipes[r]
    check(r .. " recipe", rec and rec.enabled, "")
  end
  local fac = nil
  for _, rec in buildings.for_force(F, "factory") do fac = rec.entity break end
  if fac then
    for _, r in ipairs({"rts-underground-belt", "rts-splitter", "rts-long-inserter"}) do
      local ok = pcall(function() fac.set_recipe(r) end)
      local now = fac.get_recipe()
      check(r .. " factory", ok and now and now.name == r, "now=%s", now and now.name or "none")
    end
    fac.set_recipe(nil)
  end
  local u1 = surface.create_entity({name = "underground-belt", position = {bx + 0.5, by + 16.5}, force = F, direction = defines.direction.east, type = "input"})
  local u2 = surface.create_entity({name = "underground-belt", position = {bx + 3.5, by + 16.5}, force = F, direction = defines.direction.east, type = "output"})
  local iron1, belt1 = stock("iron-plate"), stock("transport-belt")
  box(surface, bx - 0.5, by + 15.5, bx + 4.5, by + 17.5)
  check("underground pair box", #selection.get_pieces(0) == 2, "selected %d", #selection.get_pieces(0))
  r1, r2 = two_presses()
  check("underground pair refund", r2 == "done" and not u1.valid and not u2.valid
    and stock("iron-plate") - iron1 == 5 and stock("transport-belt") - belt1 == 2, "iron %+d (want 5) belts %+d (want 2)",
    stock("iron-plate") - iron1, stock("transport-belt") - belt1)
  check("registry unchanged", buildings.count(F) == registry0, "%d vs %d", buildings.count(F), registry0)
  util.log("r3 build probe done: %d failure(s)", fails)
end

events.on_nth_tick(60, function()
  local m = storage.match
  if not (m and m.tick_started) then return end
  local P = storage.r3_build_probe
  if not P then
    P = {}
    storage.r3_build_probe = P
  end
  if P.done then return end
  if not P.started then
    if m.phase ~= "running" or game.tick - m.tick_started < 120 then return end
    P.started = game.tick
    ai.stop_force(F)
    local ok, err = pcall(run)
    if not ok then
      fails = fails + 1
      util.log("r3 build probe ERROR: %s", tostring(err))
      util.log("r3 build probe done: %d failure(s)", fails)
    end
    P.finish_at = game.tick + 600
    return
  end
  if game.tick >= P.finish_at then
    P.done = true
    util.log("r3 build probe: after 10 s %d failure(s)", fails)
  end
end)
