-- r2-econ (0.1.1 follow-up) test-only diagnostic: an AI construction train that has not moved one tile for STUCK_TICKS
-- while building is logged once per position with everything that could hold it: train state, speed, path, the signal
-- it waits at, the coal of each locomotive and in the wagon, the rails aboard, the units, vehicles and rolling stock
-- around both ends, and the other trains within 150 tiles. Use with an acceptance run, e.g.
--   PERF=1 EXTRA_LUA=tools/probes/r2e_crew_diag.lua DURATION_MIN=60 SEED=804 SPEED=8 tools/autotest-run.sh r2e-diag-804 \
--     '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 9000
-- Log: "[rts] r2e crew diag train <id> ..." (several lines per stuck crew).
local events = require("scripts.events")
local util = require("scripts.util")

local STUCK_TICKS = 3600
local PERIOD = 300

local function train_of(rec)
  if rec.loco and rec.loco.valid then return rec.loco.train end
  for _, e in ipairs(rec.stock or {}) do
    if e.valid and e.train then return e.train end
  end
end

local function coal_of(train)
  local parts = {}
  for _, loco in ipairs(train.locomotives.front_movers) do
    local inv = loco.get_fuel_inventory()
    parts[#parts + 1] = string.format("F%d%s", inv and inv.get_item_count("coal") or -1,
      loco.burner and loco.burner.currently_burning and "+" or "")
  end
  for _, loco in ipairs(train.locomotives.back_movers) do
    local inv = loco.get_fuel_inventory()
    parts[#parts + 1] = string.format("B%d%s", inv and inv.get_item_count("coal") or -1,
      loco.burner and loco.burner.currently_burning and "+" or "")
  end
  local wc, wr = 0, 0
  for _, w in ipairs(train.cargo_wagons) do
    local inv = w.get_inventory(defines.inventory.cargo_wagon)
    if inv then
      wc = wc + inv.get_item_count("coal")
      wr = wr + inv.get_item_count("rail")
    end
  end
  return table.concat(parts, " "), wc, wr
end

local SKIP = {["straight-rail"] = true, ["curved-rail-a"] = true, ["curved-rail-b"] = true, ["half-diagonal-rail"] = true,
              ["rail-ramp"] = true, ["elevated-straight-rail"] = true, ["elevated-curved-rail-a"] = true,
              ["elevated-curved-rail-b"] = true, ["elevated-half-diagonal-rail"] = true, ["rail-support"] = true,
              ["rail-signal"] = true, ["rail-chain-signal"] = true, tree = true, ["simple-entity"] = true,
              ["optimized-decorative"] = true, ["entity-ghost"] = true, resource = true, ["tile-ghost"] = true}

local function around(surface, pos, r)
  local out = {}
  for _, e in ipairs(surface.find_entities_filtered({area = {{pos.x - r, pos.y - r}, {pos.x + r, pos.y + r}}})) do
    if not SKIP[e.type] then
      local extra = ""
      if e.train then extra = " train " .. e.train.id end
      out[#out + 1] = string.format("%s:%s(%s)@%s%s", e.type, e.name, e.force.name, util.pos_str(e.position), extra)
    end
    if #out >= 14 then break end
  end
  return table.concat(out, " ")
end

events.on_nth_tick(PERIOD, function(e)
  local R = storage.rails
  if not (R and R.trains) then return end
  local D = storage.r2e_crew_diag or {last = {}, logged = {}}
  storage.r2e_crew_diag = D
  for id, rec in pairs(R.trains) do
    if rec.kind == "construction" then
      local train = train_of(rec)
      local fs = train and train.valid and train.front_stock
      if fs and fs.valid then
        local p = fs.position
        local l = D.last[id]
        if not l or util.distance(l, p) > 1 then
          D.last[id] = {x = p.x, y = p.y, tick = game.tick}
        elseif game.tick - l.tick >= STUCK_TICKS and rec.state ~= "returning" then
          local key = id .. "@" .. math.floor(p.x) .. "," .. math.floor(p.y)
          if not D.logged[key] then
            D.logged[key] = game.tick
            local line = rec.line and R.lines[rec.line]
            local coal, wcoal, wrails = coal_of(train)
            util.log("r2e crew diag train %d (%s, line #%s %s, missing %s) stuck %.1f min at %s: rec %s target %s; "
              .. "train %s speed %.2f manual %s; coal %s, wagon coal %d rails %d", id, rec.force, tostring(rec.line),
              line and line.state or "-", tostring(line and line.missing), (game.tick - l.tick) / 3600, util.pos_str(p),
              tostring(rec.state), tostring(rec.target), util.define_name(defines.train_state, train.state), train.speed,
              tostring(train.manual_mode), coal, wcoal, wrails)
            local path = train.path
            local sig = train.signal
            util.log("r2e crew diag train %d: path %s (size %s, current %s, %.0f of %.0f), end rail %s; signal %s %s state %s",
              id, tostring(train.has_path), path and path.size or "-", path and path.current or "-",
              path and path.travelled_distance or 0, path and path.total_distance or 0,
              train.path_end_rail and util.pos_str(train.path_end_rail.position) or "-",
              sig and sig.name or "-", sig and util.pos_str(sig.position) or "-",
              sig and util.define_name(defines.signal_state, sig.signal_state) or "-")
            local s = fs.surface
            util.log("r2e crew diag train %d: near front: %s", id, around(s, p, 8))
            local bs = train.back_stock
            if bs and bs.valid then util.log("r2e crew diag train %d: near back: %s", id, around(s, bs.position, 8)) end
            local others = {}
            for oid, orec in pairs(R.trains) do
              local ot = oid ~= id and train_of(orec)
              local ofs = ot and ot.valid and ot.front_stock
              if ofs and ofs.valid and util.distance(ofs.position, p) < 150 then
                others[#others + 1] = string.format("%d %s %s line %s %s speed %.2f at %s", oid, orec.kind, orec.force,
                  tostring(orec.line or orec.ai_line), util.define_name(defines.train_state, ot.state), ot.speed,
                  util.pos_str(ofs.position))
              end
            end
            util.log("r2e crew diag train %d: other trains within 150 tiles: %s", id,
              #others > 0 and table.concat(others, " | ") or "none")
          end
        end
      end
    end
  end
end)
