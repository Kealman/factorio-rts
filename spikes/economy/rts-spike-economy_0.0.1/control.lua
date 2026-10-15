-- Phase 0 spikes #4 and #5 (headless, no players).
--   #4 "barracks pattern": an assembler with the rts-barracks category crafts rts-marine-kit;
--      a poller converts finished items into small-biter units at a rally point.
--   #5 "AI base": a force with no players gets a base from a blueprint string
--      (build_blueprint -> ghosts -> timed revive) and its production must run.
--   Bonus: clone_area as an alternative templating mechanism.
-- All log lines carry the "[rts-eco]" prefix. Everything is scheduled relative to the first
-- server tick (storage.t0) because on_init runs during `--create`, whose log is separate.

local P = "[rts-eco] "
local AI = "rts-ai"
local AI2 = "rts-ai-2"
local KIT = "rts-marine-kit"

local function L(fmt, ...)
  log(P .. string.format(fmt, ...))
end

local function ps(p)
  if not p then return "nil" end
  return string.format("(%.2f,%.2f)", p.x or p[1], p.y or p[2])
end

local STATUS = {}
for k, v in pairs(defines.entity_status) do STATUS[v] = k end
local function status_name(e)
  local ok, st = pcall(function() return e.status end)
  if not ok or st == nil then return "nil" end
  return STATUS[st] or tostring(st)
end

local DIR_NAME = {}
for k, v in pairs(defines.direction) do DIR_NAME[v] = k end

-- Timeline in ticks after the first server tick.
local T = {
  setup = 1,
  barracks = 30,
  template = 60,
  calibrate = 65,
  build = 75,
  obstruction = 80,
  revive_start = 90,
  bench_create = 120,
  bench_start = 600,
  bench_end = 1200,
  rate_from = 1800,
  rate_to = 5400,
  clone = 4800,
  final = 6900,
}

local TEMPLATE_ORIGIN = { x = -40, y = -40 }
local BUILD_POSITION = { x = 40, y = 40 }
local CLONE_SHIFT = { x = -80, y = 0 }
local RALLY = { x = 0, y = 8 }

-- Non-serialisable measurement state (LuaProfiler cannot live in storage). Spike only.
local bench = { accA = nil, accB = nil, nA = 0, nB = 0, touchesA = 0, touchesB = 0 }

local function surface() return game.surfaces["nauvis"] end
local function rt(tick) return tick - (storage.t0 or 0) end

---------------------------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------------------------

script.on_init(function()
  storage.t0 = nil
  storage.counters = { built_events = 0, revive_events = 0, cloned_events = 0, area_cloned_events = 0 }
  local f = game.create_force(AI)
  f.ai_controllable = false
  storage.force_created_in_init = true
  L("on_init: created force %s index=%d ai_controllable=%s players=%d", f.name, f.index,
    tostring(f.ai_controllable), #f.players)
end)

local function setup_world(tick)
  local s = surface()
  local f = game.forces[AI]
  L("setup: tick=%d force %s exists=%s index=%d ai_controllable=%s players=%d connected=%d",
    tick, AI, tostring(f ~= nil), f.index, tostring(f.ai_controllable), #f.players, #f.connected_players)
  local count = 0
  for _ in pairs(game.forces) do count = count + 1 end
  L("setup: forces total=%d (game.forces is %s)", count, type(game.forces))

  local function chunk_census()
    local gen, total = 0, 0
    for cx = -3, 2 do
      for cy = -3, 2 do
        total = total + 1
        if s.is_chunk_generated({ cx, cy }) then gen = gen + 1 end
      end
    end
    return gen, total
  end
  local g0, tot = chunk_census()
  s.request_to_generate_chunks({ 0, 0 }, 3)
  s.force_generate_chunk_requests()
  local g1 = chunk_census()
  L("setup: chunks generated in [-3..2]^2 before=%d/%d after force_generate=%d/%d", g0, tot, g1, tot)

  s.always_day = true
  local removed = 0
  for _, e in pairs(s.find_entities_filtered { area = { { -66, -66 }, { 66, 66 } } }) do
    if e.valid and e.type ~= "character" then
      e.destroy()
      removed = removed + 1
    end
  end
  local tiles = {}
  for x = -64, 63 do
    for y = -64, 63 do
      tiles[#tiles + 1] = { name = "grass-1", position = { x, y } }
    end
  end
  s.set_tiles(tiles, true, true, true, false)
  L("setup: removed %d entities, set %d grass-1 tiles over [-64,64)^2, always_day=true", removed, #tiles)
end

---------------------------------------------------------------------------------------------
-- Spike #4: barracks
---------------------------------------------------------------------------------------------

local function predict_finish(e, tick)
  local recipe = e.get_recipe()
  if not recipe then return nil end
  local remaining = (1 - e.crafting_progress) * recipe.energy / e.crafting_speed * 60
  return tick + math.ceil(remaining)
end

local function new_barracks_state(b, rally, tick)
  return {
    entity = b, rally = rally, last_pf = b.products_finished, finish_queue = {}, latencies = {},
    predict_deltas = {}, predicted = nil, spawned = 0, polls = 0, touches = 0, created_tick = tick,
    next_check = tick + 1,
  }
end

local function create_barracks(tick)
  local s = surface()
  local function make(pos)
    local b = s.create_entity { name = "rts-barracks", position = pos, force = AI, recipe = KIT }
    if not b then return nil end
    local inv = b.get_inventory(defines.inventory.assembling_machine_input)
    local iron = inv.insert { name = "iron-plate", count = 40 }
    local cu = inv.insert { name = "copper-plate", count = 20 }
    L("barracks: created at %s unit_number=%d recipe=%s crafting_speed=%.2f energy_source=void inserted iron=%d"
      .. " copper=%d (assembling_machine_input=%d crafter_input=%d)", ps(pos), b.unit_number, b.get_recipe().name,
      b.crafting_speed, iron, cu, defines.inventory.assembling_machine_input, defines.inventory.crafter_input)
    return b
  end
  local b1 = make({ 0, 0 })
  local b2 = make({ 10, 0 })
  if b1 then storage.barracks = new_barracks_state(b1, RALLY, tick) end
  if b2 then storage.pred = new_barracks_state(b2, { x = 10, y = 8 }, tick) end
end

-- Measurement only: watch products_finished every tick to learn the exact completion tick.
local function observe_barracks(st, tick, label)
  if not (st and st.entity.valid) then return end
  local pf = st.entity.products_finished
  if pf ~= st.last_pf then
    for _ = st.last_pf + 1, pf do
      st.finish_queue[#st.finish_queue + 1] = tick
    end
    if st.predicted then
      st.predict_deltas[#st.predict_deltas + 1] = tick - st.predicted
    end
    L("%s: craft finished observed tick=%d (rt=%d) products_finished=%d predicted=%s",
      label, tick, rt(tick), pf, tostring(st.predicted))
    st.last_pf = pf
    st.predicted = predict_finish(st.entity, tick)
  elseif not st.predicted and st.entity.is_crafting() then
    st.predicted = predict_finish(st.entity, tick)
  end
end

local function spawn_units(st, tick, count, label)
  local s = st.entity.surface
  for _ = 1, count do
    local pos = s.find_non_colliding_position("small-biter", st.rally, 10, 0.5)
    local unit = pos and s.create_entity { name = "small-biter", position = pos, force = AI }
    st.spawned = st.spawned + 1
    local finished = table.remove(st.finish_queue, 1)
    local latency = finished and (tick - finished) or -1
    st.latencies[#st.latencies + 1] = latency
    local crowd = s.count_entities_filtered { position = st.rally, radius = 3, type = "unit", force = AI }
    L("%s: spawn #%d tick=%d rt=%d unit=%s pos=%s finished_tick=%s latency=%d crafting_progress=%.3f"
      .. " products_finished=%d checks_so_far=%d units_within_3_of_rally=%d",
      label, st.spawned, tick, rt(tick), unit and tostring(unit.unit_number) or "FAILED", ps(pos),
      tostring(finished), latency, st.entity.crafting_progress, st.entity.products_finished, st.polls, crowd)
  end
end

-- The actual barracks mechanism (variant 1): poll output every 10 ticks, consume, spawn.
local function poll_barracks(tick)
  local st = storage.barracks
  if not (st and st.entity.valid) then return end
  st.polls = st.polls + 1
  st.touches = st.touches + 1
  local out = st.entity.get_output_inventory()
  local n = out.get_item_count(KIT)
  if n == 0 then return end
  local removed = out.remove { name = KIT, count = n }
  spawn_units(st, tick, removed, "barracks")
end

-- Variant 2: no fixed polling. Check exactly at the predicted completion tick computed from
-- crafting_progress, recipe energy and crafting_speed; re-check every 60 ticks while idle.
local function predictive_check(tick)
  local st = storage.pred
  if not (st and st.entity.valid) or tick ~= st.next_check then return end
  st.polls = st.polls + 1
  st.touches = st.touches + 1
  local out = st.entity.get_output_inventory()
  local n = out.get_item_count(KIT)
  if n > 0 then
    local removed = out.remove { name = KIT, count = n }
    spawn_units(st, tick, removed, "pred-barracks")
  end
  if st.entity.is_crafting() then
    local nt = predict_finish(st.entity, tick)
    st.next_check = (nt and nt > tick) and nt or tick + 1
  else
    st.next_check = tick + 60
  end
end

-- Cost benchmark: 90 extra barracks polled in two variants, timed with LuaProfiler.
local function create_bench(tick)
  local s = surface()
  storage.bench = { entities = {}, last_pf = {} }
  local created = 0
  for row = 0, 2 do
    for col = 0, 29 do
      local e = s.create_entity { name = "rts-barracks", position = { -59.5 + col * 4, 52.5 + row * 4 }, force = AI,
        recipe = KIT }
      if e then
        e.get_inventory(defines.inventory.assembling_machine_input).insert { name = "iron-plate", count = 10 }
        e.get_inventory(defines.inventory.assembling_machine_input).insert { name = "copper-plate", count = 5 }
        storage.bench.entities[#storage.bench.entities + 1] = e
        storage.bench.last_pf[e.unit_number] = e.products_finished
        created = created + 1
      end
    end
  end
  bench.accA = helpers.create_profiler(true)
  bench.accB = helpers.create_profiler(true)
  L("bench: created %d barracks for poll-cost measurement", created)
end

local function bench_poll(tick)
  local b = storage.bench
  if not b then return end
  local p = helpers.create_profiler(false)
  local touched = 0
  if (tick / 10) % 2 == 0 then
    -- Variant A: read the output inventory of every barracks.
    for _, e in pairs(b.entities) do
      if e.valid then
        touched = touched + 1
        local out = e.get_output_inventory()
        local n = out.get_item_count(KIT)
        if n > 0 then out.remove { name = KIT, count = n } end
      end
    end
    p.stop()
    bench.accA.add(p)
    bench.nA = bench.nA + 1
    bench.touchesA = bench.touchesA + touched
  else
    -- Variant B: compare products_finished, open the inventory only when it changed.
    for _, e in pairs(b.entities) do
      if e.valid then
        touched = touched + 1
        local pf = e.products_finished
        local key = e.unit_number
        if pf ~= b.last_pf[key] then
          b.last_pf[key] = pf
          local out = e.get_output_inventory()
          local n = out.get_item_count(KIT)
          if n > 0 then out.remove { name = KIT, count = n } end
        end
      end
    end
    p.stop()
    bench.accB.add(p)
    bench.nB = bench.nB + 1
    bench.touchesB = bench.touchesB + touched
  end
end

local function bench_report()
  if not bench.accA then return end
  local nEnt = #storage.bench.entities
  log({ "", P, "bench: variant A (get_output_inventory+get_item_count) total over ", bench.nA, " polls of ", nEnt,
    " barracks: ", bench.accA })
  log({ "", P, "bench: variant B (products_finished compare, inventory only on change) total over ", bench.nB,
    " polls of ", nEnt, " barracks: ", bench.accB })
  if bench.nA > 0 then bench.accA.divide(bench.nA) end
  if bench.nB > 0 then bench.accB.divide(bench.nB) end
  log({ "", P, "bench: variant A average per poll: ", bench.accA })
  log({ "", P, "bench: variant B average per poll: ", bench.accB })
  L("bench: entity touches A=%d B=%d (= barracks count per poll)", bench.touchesA, bench.touchesB)
end

---------------------------------------------------------------------------------------------
-- Spike #5: AI base from a blueprint
---------------------------------------------------------------------------------------------

-- Template layout relative to TEMPLATE_ORIGIN. Two lanes: burner drill -> stone furnace and
-- electric drill -> stone furnace; burner inserters put plates on a belt; an electric inserter
-- moves them into a wooden chest. Power: 2 solar panels + accumulator + 2 medium poles.
local LAYOUT = {
  { name = "burner-mining-drill", pos = { 1, 0 }, dir = "east" },
  { name = "stone-furnace", pos = { 3, 0 } },
  { name = "burner-inserter", pos = { 4.5, -0.5 }, pick = { 3.5, -0.5 } },
  { name = "electric-mining-drill", pos = { 0.5, 4.5 }, dir = "east" },
  { name = "stone-furnace", pos = { 3, 5 } },
  { name = "burner-inserter", pos = { 4.5, 4.5 }, pick = { 3.5, 4.5 } },
  { name = "inserter", pos = { 5.5, 8.5 }, pick = { 5.5, 7.5 } },
  { name = "wooden-chest", pos = { 5.5, 9.5 } },
  { name = "medium-electric-pole", pos = { 3.5, 8.5 } },
  { name = "medium-electric-pole", pos = { -2.5, 8.5 } },
  { name = "solar-panel", pos = { -3.5, 10.5 } },
  { name = "solar-panel", pos = { -0.5, 10.5 } },
  { name = "accumulator", pos = { 2, 11 } },
}
for y = -0.5, 7.5 do
  LAYOUT[#LAYOUT + 1] = { name = "transport-belt", pos = { 5.5, y }, dir = "south" }
end

local function place_ore(s, center, radius)
  local placed = 0
  for tx = math.floor(center.x - radius), math.ceil(center.x + radius) - 1 do
    for ty = math.floor(center.y - radius), math.ceil(center.y + radius) - 1 do
      local p = { tx + 0.5, ty + 0.5 }
      if s.count_entities_filtered { position = p, type = "resource" } == 0 then
        if s.create_entity { name = "iron-ore", position = p, amount = 5000 } then placed = placed + 1 end
      end
    end
  end
  return placed
end

local function abs_pos(rel)
  return { x = TEMPLATE_ORIGIN.x + rel[1], y = TEMPLATE_ORIGIN.y + rel[2] }
end

local function near(a, b, eps)
  return math.abs(a.x - b.x) < eps and math.abs(a.y - b.y) < eps
end

local function build_template(tick)
  local s = surface()
  local f = game.forces[AI]
  local ore = 0
  for _, spec in ipairs(LAYOUT) do
    if spec.name:find("mining%-drill") then
      ore = ore + place_ore(s, abs_pos(spec.pos), prototypes.entity[spec.name].mining_drill_radius)
    end
  end
  local ents, failed = {}, 0
  for _, spec in ipairs(LAYOUT) do
    local pos = abs_pos(spec.pos)
    local e
    if spec.pick then
      -- Find the direction whose pickup_position matches the intended pickup tile.
      local want = abs_pos(spec.pick)
      for _, d in ipairs({ "north", "east", "south", "west" }) do
        e = s.create_entity { name = spec.name, position = pos, direction = defines.direction[d], force = f }
        if e and near(e.pickup_position, want, 0.3) then
          L("template: %s at %s picks %s drops %s with direction=%s", spec.name, ps(e.position),
            ps(e.pickup_position), ps(e.drop_position), d)
          break
        end
        if e then e.destroy() end
        e = nil
      end
    else
      e = s.create_entity { name = spec.name, position = pos, direction = spec.dir and defines.direction[spec.dir] or nil,
        force = f }
    end
    if e then ents[#ents + 1] = e else failed = failed + 1; L("template: FAILED to create %s at %s", spec.name, ps(pos)) end
  end
  -- Wire the two medium poles explicitly if create_entity did not auto-connect them.
  local poles = {}
  for _, e in ipairs(ents) do if e.type == "electric-pole" then poles[#poles + 1] = e end end
  if #poles == 2 then
    local c1 = poles[1].get_wire_connector(defines.wire_connector_id.pole_copper, true)
    local c2 = poles[2].get_wire_connector(defines.wire_connector_id.pole_copper, true)
    local auto = c1.is_connected_to(c2)
    if not auto then c1.connect_to(c2) end
    L("template: poles auto-connected by create_entity=%s, now connected=%s, network ids %s/%s", tostring(auto),
      tostring(c1.is_connected_to(c2)), tostring(poles[1].electric_network_id), tostring(poles[2].electric_network_id))
  end
  L("template: placed %d ore tiles, created %d entities, %d failed, at origin %s", ore, #ents, failed,
    ps(TEMPLATE_ORIGIN))

  -- Blueprint from the template via a script inventory (no player involved).
  local inv = game.create_inventory(1)
  local stack = inv[1]
  local set_ok = stack.set_stack("blueprint")
  local area = { { TEMPLATE_ORIGIN.x - 6, TEMPLATE_ORIGIN.y - 3 }, { TEMPLATE_ORIGIN.x + 8, TEMPLATE_ORIGIN.y + 14 } }
  local mapping = stack.create_blueprint { surface = s, force = f, area = area }
  local str = stack.export_stack()
  local bp_ents = stack.get_blueprint_entities() or {}
  L("template: set_stack=%s create_blueprint mapped %d entities, get_blueprint_entities=%d, export_stack length=%d"
    .. " prefix=%q", tostring(set_ok), table_size(mapping), #bp_ents, #str, str:sub(1, 16))
  for i = 1, math.min(3, #bp_ents) do
    L("template: bp entity %d %s rel_pos=%s dir=%s", bp_ents[i].entity_number, bp_ents[i].name, ps(bp_ents[i].position),
      tostring(bp_ents[i].direction))
  end
  local ok_dec, json = pcall(helpers.decode_string, str:sub(2))
  if ok_dec and json then
    local t = helpers.json_to_table(json)
    local bp = t and t.blueprint
    local e1 = bp and bp.entities and bp.entities[1]
    L("template: string = version char %q + base64(zlib(JSON)); JSON length=%d, blueprint.version=%s, entities=%d,"
      .. " first stored entity %s pos=%s", str:sub(1, 1), #json, tostring(bp and bp.version),
      bp and bp.entities and #bp.entities or -1, e1 and e1.name or "?", ps(e1 and e1.position))
  else
    L("template: decode_string failed: %s", tostring(json))
  end
  storage.bp_string = str
  storage.template_first = { name = ents[1].name, pos = ents[1].position }
  inv.destroy()

  -- Remove the originals; the template only lives on as a string now.
  local destroyed = 0
  for _, e in ipairs(ents) do
    if e.valid then e.destroy(); destroyed = destroyed + 1 end
  end
  L("template: destroyed %d original entities (ore left in place)", destroyed)
end

-- Blueprints never contain resources, and mining-drill ghosts cannot be placed without ore.
-- To put ore (or pick a site) before building, learn the template's layout transform once:
-- build it on a scratch surface fully covered with ore at P0=(0,0) and record ghost offsets.
local function calibrate(tick)
  local s = game.surfaces["rts-templates"] or game.create_surface("rts-templates")
  s.request_to_generate_chunks({ 0, 0 }, 1)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered { area = { { -32, -32 }, { 32, 32 } } }) do e.destroy() end
  local tiles = {}
  for x = -32, 31 do
    for y = -32, 31 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
  end
  s.set_tiles(tiles, true, true, true, false)
  place_ore(s, { x = 0, y = 0 }, 20)
  local inv = game.create_inventory(1)
  local stack = inv[1]
  stack.import_stack(storage.bp_string)
  local ghosts = stack.build_blueprint { surface = s, force = AI, position = { 0, 0 } }
  inv.destroy()
  local layout = {}
  for _, g in ipairs(ghosts) do
    layout[#layout + 1] = { name = g.ghost_name, rel = { x = g.position.x, y = g.position.y }, dir = g.direction,
      radius = g.ghost_type == "mining-drill" and g.ghost_prototype.mining_drill_radius or nil }
    g.destroy()
  end
  storage.layout = layout
  local drills = 0
  for _, l in ipairs(layout) do if l.radius then drills = drills + 1 end end
  -- Relationship between template world positions and blueprint-relative positions.
  local tf = storage.template_first
  local match
  for _, l in ipairs(layout) do
    if l.name == tf.name then match = l; break end
  end
  L("calibrate: scratch surface %s, built %d ghosts at P0=(0,0) (normal mode, ore everywhere), drills=%d;"
    .. " template %s at %s -> rel %s", s.name, #layout, drills, tf.name, ps(tf.pos), ps(match and match.rel))
end

local function ghost_census(ghosts)
  local by_name = {}
  for _, g in ipairs(ghosts) do
    if g.valid then by_name[g.ghost_name] = (by_name[g.ghost_name] or 0) + 1 end
  end
  local parts = {}
  for k, v in pairs(by_name) do parts[#parts + 1] = k .. "=" .. v end
  table.sort(parts)
  return table.concat(parts, " ")
end

local function try_build(stack, s, f, mode_name)
  local ok, ghosts = pcall(function()
    return stack.build_blueprint { surface = s, force = f, position = BUILD_POSITION,
      build_mode = defines.build_mode[mode_name], raise_built = true }
  end)
  if not ok then
    L("build: build_blueprint(%s) ERROR: %s", mode_name, tostring(ghosts))
    return {}
  end
  return ghosts
end

local function build_from_string(tick)
  local s = surface()
  local f = game.forces[AI]
  local inv = game.create_inventory(1)
  local stack = inv[1]
  local rc = stack.import_stack(storage.bp_string)
  L("build: import_stack rc=%d (0=ok) valid_for_read=%s is_blueprint_setup=%s", rc, tostring(stack.valid_for_read),
    tostring(stack.valid_for_read and stack.is_blueprint_setup()))
  local cx, cy = math.floor(BUILD_POSITION.x / 32), math.floor(BUILD_POSITION.y / 32)
  L("build: force %s players=%d chunk (%d,%d) charted=%s visible=%s", f.name, #f.players, cx, cy,
    tostring(f.is_chunk_charted(s, { cx, cy })), tostring(f.is_chunk_visible(s, { cx, cy })))

  -- Attempt 1: no ore at the site yet, normal mode (expected all-or-nothing).
  local g1 = try_build(stack, s, f, "normal")
  L("build: attempt 1 (no ore, build_mode=normal, no player) -> %d ghosts [%s]", #g1, ghost_census(g1))
  for _, g in ipairs(g1) do if g.valid then g.destroy() end end

  -- Pre-place ore under the drills using the calibrated layout.
  local ore = 0
  for _, l in ipairs(storage.layout or {}) do
    if l.radius then
      ore = ore + place_ore(s, { x = BUILD_POSITION.x + l.rel.x, y = BUILD_POSITION.y + l.rel.y }, l.radius)
    end
  end
  L("build: placed %d ore tiles under predicted drill positions", ore)

  -- Attempt 2: normal mode with ore in place; fall back to forced if needed.
  local before_events = storage.counters.built_events
  local ghosts = try_build(stack, s, f, "normal")
  local mode = "normal"
  if #ghosts == 0 then
    ghosts = try_build(stack, s, f, "forced")
    mode = "forced"
  end
  inv.destroy()
  L("build: attempt 2 (ore placed, build_mode=%s, no player) -> %d ghosts [%s]; script_raised_built events=%d",
    mode, #ghosts, ghost_census(ghosts), storage.counters.built_events - before_events)

  -- Verify the calibrated transform: every ghost at P + rel with the same name.
  local predicted = {}
  for _, l in ipairs(storage.layout or {}) do
    predicted[string.format("%s@%.1f,%.1f", l.name, BUILD_POSITION.x + l.rel.x, BUILD_POSITION.y + l.rel.y)] = true
  end
  local matched = 0
  for _, g in ipairs(ghosts) do
    if predicted[string.format("%s@%.1f,%.1f", g.ghost_name, g.position.x, g.position.y)] then matched = matched + 1 end
  end
  L("build: calibrated positions matched %d/%d ghosts (translation P + rel holds for integer P)", matched, #ghosts)

  if ghosts[1] then
    local g = ghosts[1]
    local ok_ttl, ttl = pcall(function() return g.time_to_live end)
    L("build: ghost[1] %s at %s type=%s force=%s time_to_live read ok=%s value=%s", g.ghost_name, ps(g.position), g.type,
      g.force.name, tostring(ok_ttl), tostring(ttl))
    L("build: force.create_ghost_on_entity_death=%s (2.0 replaced ghost_time_to_live with this bool)",
      tostring(f.create_ghost_on_entity_death))
  end

  -- Keep one ghost (accumulator) unrevived as an expiry control.
  storage.revive = { ghosts = ghosts, idx = 1, revived = {}, failed = 0, started = nil, finished = nil }
  for _, g in ipairs(ghosts) do
    if g.ghost_name == "accumulator" then
      storage.control_ghost = g
      break
    end
  end
end

-- Obstruction test at a separate site: how do normal / forced / superforced handle a tree
-- (nature) and a foreign-force chest sitting where the first stone furnace goes?
local OBSTRUCTION_SITE = { x = 40, y = -40 }

local function obstruction_test(tick)
  local s = surface()
  local f = game.forces[AI]
  local layout = storage.layout or {}
  local P = OBSTRUCTION_SITE
  local furnace_pos
  for _, l in ipairs(layout) do
    if l.radius then place_ore(s, { x = P.x + l.rel.x, y = P.y + l.rel.y }, l.radius) end
    if not furnace_pos and l.name == "stone-furnace" then furnace_pos = { x = P.x + l.rel.x, y = P.y + l.rel.y } end
  end
  local inv = game.create_inventory(1)
  local stack = inv[1]
  stack.import_stack(storage.bp_string)
  local function build(mode)
    local ok, ghosts = pcall(function()
      return stack.build_blueprint { surface = s, force = f, position = P, build_mode = defines.build_mode[mode] }
    end)
    if not ok then
      L("obstruct: build %s ERROR %s", mode, tostring(ghosts))
      return {}
    end
    return ghosts
  end
  local function furnace_ghost()
    return s.find_entities_filtered { position = furnace_pos, radius = 0.6, name = "entity-ghost", ghost_name = "stone-furnace" }[1]
  end
  local function clear()
    for _, e in pairs(s.find_entities_filtered { area = { { P.x - 8, P.y - 8 }, { P.x + 8, P.y + 9 } }, force = AI }) do
      e.destroy()
    end
  end

  local cases = {
    { obstacle = "tree-01", force = "neutral" },
    { obstacle = "wooden-chest", force = "neutral" },
    { obstacle = "wooden-chest", force = AI },
  }
  for _, case in ipairs(cases) do
    for _, mode in ipairs({ "normal", "forced", "superforced" }) do
      local obstacle = s.create_entity { name = case.obstacle, position = furnace_pos, force = case.force }
      local ghosts = build(mode)
      local fg = furnace_ghost()
      local decon = obstacle and obstacle.valid and obstacle.to_be_deconstructed()
      local result = "no furnace ghost"
      if fg then
        local _, ent = fg.revive {}
        if ent then
          result = "revive ok"
        elseif obstacle and obstacle.valid then
          -- Script stands in for a construction robot: remove the obstacle, then retry.
          obstacle.destroy()
          local ent2
          if fg.valid then
            local _r, e2 = fg.revive {}
            ent2 = e2
          end
          result = "revive blocked; after destroying obstacle: " .. (ent2 and "revive ok" or "still nil")
        end
      end
      L("obstruct: %s(%s) mode=%s -> %d ghosts, furnace ghost=%s, obstacle marked_for_deconstruction=%s, %s",
        case.obstacle, case.force, mode, #ghosts, tostring(fg ~= nil), tostring(decon), result)
      clear()
      if obstacle and obstacle.valid then obstacle.destroy() end
    end
  end
  inv.destroy()
end

local function revive_step(tick)
  local r = storage.revive
  if not r or r.finished or rt(tick) < T.revive_start then return end
  r.started = r.started or tick
  local done = 0
  while done < 3 and r.idx <= #r.ghosts do
    local g = r.ghosts[r.idx]
    r.idx = r.idx + 1
    if g.valid and g ~= storage.control_ghost then
      local name, pos = g.ghost_name, g.position
      local collided, ent, proxy = g.revive { raise_revive = true }
      if ent then
        r.revived[#r.revived + 1] = ent
      else
        r.failed = r.failed + 1
      end
      L("revive: tick=%d rt=%d %s at %s -> entity=%s collided=%s proxy=%s", tick, rt(tick), name, ps(pos),
        ent and tostring(ent.unit_number or ent.name) or "nil", collided and tostring(#collided) or "nil",
        tostring(proxy ~= nil))
      done = done + 1
    end
  end
  if r.idx > #r.ghosts then
    r.finished = tick
    L("revive: done at tick=%d, revived=%d failed=%d, took %d ticks from first revive; revive events=%d",
      tick, #r.revived, r.failed, tick - r.started, storage.counters.revive_events)
    local poles = {}
    for _, e in ipairs(r.revived) do if e.valid and e.type == "electric-pole" then poles[#poles + 1] = e end end
    if #poles == 2 then
      local c1 = poles[1].get_wire_connector(defines.wire_connector_id.pole_copper, false)
      local c2 = poles[2].get_wire_connector(defines.wire_connector_id.pole_copper, false)
      L("revive: poles wire-connected after revive=%s, network ids %s/%s", tostring(c1 and c2 and c1.is_connected_to(c2)),
        tostring(poles[1].electric_network_id), tostring(poles[2].electric_network_id))
    end
  end
end

-- Fuel arrives with "construction": the revive event handler inserts coal into burners.
local function on_revive(e)
  storage.counters.revive_events = storage.counters.revive_events + 1
  local ent = e.entity
  if ent and ent.valid and ent.burner then
    local fuel = ent.get_fuel_inventory()
    local n = fuel and fuel.insert { name = "coal", count = 10 } or 0
    L("revive-event: %s fuelled with %d coal", ent.name, n)
  end
end

local function line_items(e)
  local total = 0
  for i = 1, e.get_max_transport_line_index() do
    total = total + e.get_transport_line(i).get_item_count()
  end
  return total
end

local function report_base(label, ents, force_name)
  if not ents or #ents == 0 then return end
  local s = surface()
  local chest, belt, parts = 0, 0, {}
  for _, e in ipairs(ents) do
    if e.valid then
      if e.type == "container" then
        chest = chest + e.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
      elseif e.type == "transport-belt" then
        belt = belt + line_items(e)
      elseif e.type == "furnace" then
        parts[#parts + 1] = string.format("furnace{ore=%d plate=%d coal=%d %s}",
          e.get_inventory(defines.inventory.furnace_source).get_item_count("iron-ore"),
          e.get_inventory(defines.inventory.furnace_result).get_item_count("iron-plate"),
          e.get_fuel_inventory().get_item_count("coal"), status_name(e))
      elseif e.type == "mining-drill" then
        parts[#parts + 1] = string.format("%s{%s}", e.name, status_name(e))
      elseif e.type == "solar-panel" or e.type == "electric-pole" then
        -- summarised below
      elseif e.type == "inserter" then
        parts[#parts + 1] = string.format("%s{%s}", e.name, status_name(e))
      end
    end
  end
  local stats = game.forces[force_name].get_item_production_statistics(s)
  L("%s: chest_plates=%d belt_items=%d force_produced plate=%d ore=%d | %s", label, chest, belt,
    stats.get_input_count("iron-plate"), stats.get_input_count("iron-ore"), table.concat(parts, " "))
  return chest, stats.get_input_count("iron-plate")
end

---------------------------------------------------------------------------------------------
-- Bonus: clone_area
---------------------------------------------------------------------------------------------

local function clone_base(tick)
  local r = storage.revive
  if not r or #r.revived == 0 then return end
  local s = surface()
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, e in ipairs(r.revived) do
    if e.valid then
      local bb = e.bounding_box
      x1 = math.min(x1, bb.left_top.x); y1 = math.min(y1, bb.left_top.y)
      x2 = math.max(x2, bb.right_bottom.x); y2 = math.max(y2, bb.right_bottom.y)
    end
  end
  x1, y1, x2, y2 = math.floor(x1) - 2, math.floor(y1) - 2, math.ceil(x2) + 2, math.ceil(y2) + 2
  local src = { { x1, y1 }, { x2, y2 } }
  local dst = { { x1 + CLONE_SHIFT.x, y1 + CLONE_SHIFT.y }, { x2 + CLONE_SHIFT.x, y2 + CLONE_SHIFT.y } }
  local f2 = game.forces[AI2] or game.create_force(AI2)
  local function count(area, force)
    return s.count_entities_filtered { area = area, force = force }
  end
  L("clone: src=%s..%s dst=%s..%s before: src(%s)=%d src(resources)=%d dst(%s)=%d dst(all)=%d", ps(src[1]), ps(src[2]),
    ps(dst[1]), ps(dst[2]), AI, count(src, AI), s.count_entities_filtered { area = src, type = "resource" }, AI2,
    count(dst, AI2), s.count_entities_filtered { area = dst })
  local before_events = storage.counters.cloned_events
  local p = helpers.create_profiler(false)
  s.clone_area { source_area = src, destination_area = dst, destination_force = f2, clone_entities = true,
    clone_tiles = true, clear_destination_entities = true, expand_map = false }
  p.stop()
  log({ "", P, "clone: clone_area took ", p })
  L("clone: after: src(%s)=%d dst(%s)=%d dst(resources)=%d dst(ghosts)=%d on_entity_cloned events=%d area_cloned=%d",
    AI, count(src, AI), AI2, count(dst, AI2), s.count_entities_filtered { area = dst, type = "resource" },
    s.count_entities_filtered { area = dst, type = "entity-ghost" }, storage.counters.cloned_events - before_events,
    storage.counters.area_cloned_events)
  local cloned = s.find_entities_filtered { area = dst, force = AI2 }
  storage.clone_entities = cloned
  local fuel, plates, net = 0, 0, {}
  for _, e in ipairs(cloned) do
    if e.burner then fuel = fuel + e.get_fuel_inventory().get_item_count("coal") end
    if e.type == "container" then plates = plates + e.get_inventory(defines.inventory.chest).get_item_count("iron-plate") end
    if e.type == "electric-pole" then net[#net + 1] = tostring(e.electric_network_id) end
  end
  L("clone: cloned state preserved: coal in burners=%d chest plates=%d pole network ids=%s", fuel, plates,
    table.concat(net, "/"))
end

---------------------------------------------------------------------------------------------
-- Final summary
---------------------------------------------------------------------------------------------

local function summary(tick)
  for _, pair in ipairs({ { "barracks (10-tick poll)", storage.barracks }, { "pred-barracks (predicted tick)", storage.pred } }) do
    local label, st = pair[1], pair[2]
    if st then
      local mn, mx, sum = math.huge, -math.huge, 0
      for _, l in ipairs(st.latencies) do mn = math.min(mn, l); mx = math.max(mx, l); sum = sum + l end
      local n = #st.latencies
      local pd = {}
      for _, d in ipairs(st.predict_deltas) do pd[#pd + 1] = tostring(d) end
      L("SUMMARY #4 %s: spawned=%d products_finished=%d checks=%d entity_touches=%d (%.1f checks per spawn)"
        .. " latency min=%s max=%s avg=%.2f ticks; predicted-vs-observed completion deltas: %s",
        label, st.spawned, st.entity.valid and st.entity.products_finished or -1, st.polls, st.touches,
        st.spawned > 0 and st.polls / st.spawned or 0, n > 0 and tostring(mn) or "-", n > 0 and tostring(mx) or "-",
        n > 0 and sum / n or 0, table.concat(pd, ","))
    end
  end
  bench_report()
  local r = storage.revive
  if r then
    L("SUMMARY #5: ghosts=%d revived=%d failed=%d control ghost (accumulator) still valid at rt=%d: %s",
      #r.ghosts, #r.revived, r.failed, rt(tick), tostring(storage.control_ghost and storage.control_ghost.valid))
    local m = storage.rate
    if m and m.plates_to then
      local minutes = (m.tick_to - m.tick_from) / 3600
      L("SUMMARY #5: iron plates produced by %s between rt=%d and rt=%d: %d (%.1f plates/min), chest +%d", AI,
        rt(m.tick_from), rt(m.tick_to), m.plates_to - m.plates_from, (m.plates_to - m.plates_from) / minutes,
        m.chest_to - m.chest_from)
    end
  end
  L("SUMMARY: counters built_events=%d revive_events=%d cloned_events=%d area_cloned=%d", storage.counters.built_events,
    storage.counters.revive_events, storage.counters.cloned_events, storage.counters.area_cloned_events)
  local units = surface().count_entities_filtered { force = AI, type = "unit" }
  L("SUMMARY: %s units on map=%d, force players=%d", AI, units, #game.forces[AI].players)
end

---------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------

local STEPS = {
  [T.setup] = setup_world,
  [T.barracks] = create_barracks,
  [T.template] = build_template,
  [T.calibrate] = calibrate,
  [T.build] = build_from_string,
  [T.obstruction] = obstruction_test,
  [T.bench_create] = create_bench,
  [T.clone] = clone_base,
  [T.final] = summary,
}

script.on_event(defines.events.on_tick, function(e)
  if not storage.t0 then
    storage.t0 = e.tick
    L("first server tick=%d; timeline is relative to it", e.tick)
  end
  observe_barracks(storage.barracks, e.tick, "barracks")
  observe_barracks(storage.pred, e.tick, "pred-barracks")
  predictive_check(e.tick)
  local step = STEPS[rt(e.tick)]
  if step then
    local ok, err = pcall(step, e.tick)
    if not ok then L("STEP ERROR at rt=%d: %s", rt(e.tick), tostring(err)) end
  end
end)

script.on_nth_tick(10, function(e)
  if not storage.t0 then return end
  poll_barracks(e.tick)
  local r = rt(e.tick)
  if r >= T.bench_start and r < T.bench_end then bench_poll(e.tick) end
end)

script.on_nth_tick(30, function(e)
  if not storage.t0 then return end
  revive_step(e.tick)
  local r = storage.revive
  if r and r.started and not storage.first_plate then
    local n = game.forces[AI].get_item_production_statistics(surface()).get_input_count("iron-plate")
    if n > 0 then
      storage.first_plate = e.tick
      L("base: first iron plate produced by %s at rt=%d (%d ticks after first revive, %s ticks after last revive)",
        AI, rt(e.tick), e.tick - r.started, r.finished and tostring(e.tick - r.finished) or "n/a")
    end
  end
end)

script.on_nth_tick(600, function(e)
  if not storage.t0 or not storage.revive then return end
  local r = rt(e.tick)
  local chest, plates = report_base(string.format("base rt=%d", r), storage.revive.revived, AI)
  storage.rate = storage.rate or {}
  local m = storage.rate
  if chest and r >= T.rate_from and not m.tick_from then
    m.tick_from, m.plates_from, m.chest_from = e.tick, plates, chest
  end
  if chest and r >= T.rate_to and not m.tick_to then
    m.tick_to, m.plates_to, m.chest_to = e.tick, plates, chest
  end
  if storage.clone_entities then
    report_base(string.format("clone rt=%d", r), storage.clone_entities, AI2)
  end
end)

script.on_event(defines.events.script_raised_built, function()
  storage.counters.built_events = storage.counters.built_events + 1
end)
script.on_event(defines.events.script_raised_revive, on_revive)
script.on_event(defines.events.on_entity_cloned, function()
  storage.counters.cloned_events = storage.counters.cloned_events + 1
end)
script.on_event(defines.events.on_area_cloned, function()
  storage.counters.area_cloned_events = storage.counters.area_cloned_events + 1
end)
