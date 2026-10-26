-- 0.1.2 (#31 part A; docs/qa/release-0-1-2-r3-rails-notes.md): the Rail tool, player-built track. Nation mode only.
--
-- Why a tool of our own: on 2.1 the vanilla rail planner does not run under the RTS remote view (probe
-- tools/probes/r3_rails_planner_gui.lua: a "rail" cursor ghost places single straight pieces, a drag a row of them, no
-- curves; a rail item vanishes from the remote cursor). The Rail button of the build menu (Economy) opens this tool:
--   left click     a waypoint. The first one is where the track starts: an own rail (a piece or an end: the new track
--                  branches from it), a depot or station platform (its track), or free ground. Every further click
--                  plans a segment from the last waypoint to the click with the line planner (rails.plan_segment:
--                  curves, diagonals, bridges with Space Age; along own track where that is shorter); a click on an own
--                  rail joins it. The segment's ghosts appear at once, its bill shows as flying text ("Track: 34
--                  pieces, 52 rails, 4 signals").
--   right click    undo the last segment (its ghosts go; built pieces stay); Backspace does the same.
--   Q / Done       the tool ends; the planned track stays and is built.
-- A segment may not cross another nation's land (territory.can_build, the rule of all infrastructure: own or neutral
-- land): it is refused with the territory message. Robots of depot, hub and city networks in range build the ghosts;
-- a construction crew comes from the nearest depot connected by track (rails.lua dispatch_manual) and builds a segment
-- in order once the track before it stands. Junctions (a segment starting on or joining existing track) get a pair of
-- chain signals on every track that meets there, and the track every signal_spacing tiles a chain pair: player track
-- is single and runs both ways, so a train enters a stretch only when its path to its next stop is free.
--
-- Owns storage.railtool = {tools = {[player_index] = T}}; T = {head = nil | {kind = "rail", rail} | {kind = "point",
-- x, y} | {kind = "state", x, y, d, l, line}, origin (the first head), segments = {line ids}, pending = line id,
-- target, bill_rails, surface, objs = {render objects}}.
-- API: railtool.open(player), railtool.close(player, why), railtool.is_open(player), railtool.click(player, position)
-- -> ok, reason, railtool.undo(player) -> ok. Log lines "[rts] railtool: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local rails = require("scripts.rails")

local railtool = {}
railtool.FRAME = "rts_railtool_frame"
local PREFIX = "rts_railtool_"
railtool.SNAP = 2.5          -- a click this close to an own rail picks that rail
railtool.MAX_SEGMENT = 600   -- tiles from waypoint to waypoint
local RAIL_TYPES = {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail"}
local RD = defines.rail_direction
local floor = math.floor

local function S()
  storage.railtool = storage.railtool or {}
  storage.railtool.tools = storage.railtool.tools or {}
  return storage.railtool
end

local function tool(player_index) return S().tools[player_index] end

function railtool.is_open(player) return player ~= nil and tool(player.index) ~= nil end

local function flying(player, text)
  if player and player.valid then player.create_local_flying_text({text = text, create_at_cursor = true}) end
end

local function clear_marks(T)
  for _, o in ipairs(T.objs or {}) do
    if o.valid then o.destroy() end
  end
  T.objs = {}
end

local function mark(player, T, pos, color)
  T.objs = T.objs or {}
  local surface = player.surface
  T.objs[#T.objs + 1] = rendering.draw_circle({color = color, radius = 1.2, width = 3, filled = false, target = pos,
    surface = T.surface and game.surfaces[T.surface] or surface, players = {player.index}, render_mode = "game"})
  T.objs[#T.objs + 1] = rendering.draw_circle({color = color, radius = 6, width = 4, filled = false, target = pos,
    surface = T.surface and game.surfaces[T.surface] or surface, players = {player.index}, render_mode = "chart"})
end

local function panel(player)
  local T = tool(player.index)
  local screen = player.gui.screen
  local frame = screen[railtool.FRAME]
  if not T then
    if frame then frame.destroy() end
    return
  end
  if not frame then
    frame = screen.add({type = "frame", name = railtool.FRAME, direction = "vertical", style = "rts_hud_frame"})
    frame.style.width = 330
    local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    row.add({type = "label", style = "rts_hud_heading_label", caption = {"rts.railtool-title"}})
    row.add({type = "empty-widget", style = "rts_hud_filler"})
    row.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
      tooltip = {"rts.railtool-done-tooltip"}, tags = {rts_railtool = "done"}})
    local hint = frame.add({type = "label", name = PREFIX .. "hint", style = "rts_hud_dim_label",
      caption = {"rts.railtool-hint"}})
    hint.style.single_line = false
    hint.style.maximal_width = 310
    local st = frame.add({type = "label", name = PREFIX .. "state", style = "rts_hud_label", caption = ""})
    st.style.single_line = false
    st.style.maximal_width = 310
    local b = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    b.add({type = "button", name = PREFIX .. "undo", caption = {"rts.railtool-undo"}, style = "rts_hud_button",
      tooltip = {"rts.railtool-undo-tooltip"}, tags = {rts_railtool = "undo"}})
    b.add({type = "button", name = PREFIX .. "done", caption = {"rts.railtool-done"}, style = "rts_hud_button",
      tooltip = {"rts.railtool-done-tooltip"}, tags = {rts_railtool = "done"}})
    local res = player.display_resolution
    frame.location = {floor(res.width / 2 - 165 * player.display_scale), floor(90 * player.display_scale)}
  end
  local st = frame[PREFIX .. "state"]
  if st then
    local text
    if T.pending then text = {"rts.railtool-state-planning"}
    elseif not T.head then text = {"rts.railtool-state-start"}
    else text = {"rts.railtool-state-next", #T.segments, T.bill_rails or 0} end
    st.caption = text
  end
end

--- Open the Rail tool for a player (Railways researched, Nation mode). Returns true when open.
function railtool.open(player)
  if not (player and player.valid) then return false end
  if not rails.nation() then return false end
  local research = package.loaded["__" .. script.mod_name .. "__/scripts/research.lua"] or package.loaded["scripts.research"]
  if research and research.is_unlocked and not research.is_unlocked(player.force.name, "rts-rail") then
    flying(player, {"rts.railtool-locked"})
    util.log("railtool: refused player=%d (Railways not researched)", player.index)
    return false
  end
  local s = S()
  if s.tools[player.index] then return true end
  s.tools[player.index] = {segments = {}, objs = {}, surface = player.surface.index}
  selection.clear(player.index)
  panel(player)
  util.log("railtool: opened player=%d", player.index)
  return true
end

function railtool.close(player, why)
  local T = tool(player.index)
  if not T then return end
  clear_marks(T)
  S().tools[player.index] = nil
  panel(player)
  util.log("railtool: closed player=%d (%s), %d segments planned", player.index, why or "-", #T.segments)
end

function railtool.toggle(player)
  if tool(player.index) then railtool.close(player, "toggle") return false end
  return railtool.open(player)
end

-- The own ground rail nearest to `pos` within SNAP tiles, or nil.
local function rail_at(surface, force_name, pos)
  local best, bd
  for _, e in ipairs(surface.find_entities_filtered({position = pos, radius = railtool.SNAP, type = RAIL_TYPES,
                                                      force = force_name})) do
    local d = util.distance_sq(e.position, pos)
    if not bd or d < bd then best, bd = e, d end
  end
  return best
end

local function snap(v) return 2 * floor(v / 2 + 0.5) end

-- Rail end states of a head: where the next segment may start. A free point offers both parities of the 2x2 grid (a
-- north-south rail end lies on an odd x and an even y, an east-west one the other way round) in 8 directions.
local function starts_of(T)
  local h = T.head
  local out = {}
  if h.kind == "state" then
    out[1] = {x = h.x, y = h.y, d = h.d, l = h.l}
  elseif h.kind == "rail" then
    if not h.rail.valid then return out end -- (the rail is gone: no start)
    for _, rd in ipairs({RD.front, RD.back}) do
      local loc = h.rail.get_rail_end(rd).location
      if loc.rail_layer == 0 then
        out[#out + 1] = {x = loc.position.x, y = loc.position.y, d = loc.direction, l = 0}
      end
    end
  else
    for dx = 0, 1 do
      for dy = 0, 1 do
        for d = 0, 14, 2 do out[#out + 1] = {x = h.x + dx, y = h.y + dy, d = d, l = 0} end
      end
    end
  end
  return out
end
railtool.starts_of = function(head) return starts_of({head = head}) end -- (fixtures)

-- Goal states of a click: onto an own rail (the track arrives at one of its ends, heading into it), or anywhere near
-- the point in any direction.
local function goals_of(rail, pos)
  local out = {}
  if rail then
    for _, rd in ipairs({RD.front, RD.back}) do
      local loc = rail.get_rail_end(rd).location
      if loc.rail_layer == 0 then
        out[#out + 1] = {x = loc.position.x, y = loc.position.y, d = (loc.direction + 8) % 16, l = 0}
      end
    end
    return out
  end
  local x, y = snap(pos.x), snap(pos.y)
  for dx = -2, 2 do
    for dy = -2, 2 do
      for d = 0, 15 do out[#out + 1] = {x = x + dx, y = y + dy, d = d, l = 0} end
    end
  end
  return out
end
railtool.goals_of = goals_of -- (fixtures)

--- A waypoint at `position` (the left click). Returns true, or false and a reason.
function railtool.click(player, position)
  local T = tool(player.index)
  if not T then return false, "closed" end
  local surface = player.surface
  T.surface = surface.index
  if T.pending then
    flying(player, {"rts.railtool-wait"})
    return false, "planning"
  end
  local rail = rail_at(surface, player.force.name, position)
  if T.head and T.head.kind == "rail" and rail == T.head.rail then return false, "same-rail" end
  if not T.head then
    if rail then
      T.head = {kind = "rail", rail = rail}
      mark(player, T, rail.position, {r = 0.3, g = 1, b = 0.4})
    else
      T.head = {kind = "point", x = snap(position.x), y = snap(position.y)}
      mark(player, T, {x = T.head.x, y = T.head.y}, {r = 1, g = 0.85, b = 0.3})
    end
    T.origin = T.head
    util.log("railtool: start %s at %s player=%d", T.head.kind, util.pos_str(rail and rail.position or position),
      player.index)
    panel(player)
    return true
  end
  local starts = starts_of(T)
  local goals = goals_of(rail, position)
  if #starts == 0 or #goals == 0 then return false, "no-route" end
  local start_rail = T.head.kind == "rail" and T.head.rail or nil
  local id, why = rails.plan_segment(player.force.name, {starts = starts, goals = goals, surface = surface.index,
    start_rail = start_rail, end_rail = rail, prev = T.head.kind == "state" and T.head.line or nil, tool = player.index,
    own_land = true, max_length = railtool.MAX_SEGMENT})
  util.log("railtool: segment to %s%s: line %s (%s) player=%d", util.pos_str(position), rail and " (onto a rail)" or "",
    tostring(id), tostring(why), player.index)
  if not id then
    flying(player, {"rts.railtool-refused", {"rts.rails-why-" .. tostring(why)}})
    return false, why
  end
  T.pending = id
  T.target = {x = position.x, y = position.y, rail = rail}
  panel(player)
  return true
end

-- rails.lua: a segment's survey ended (ghosts placed, or failed).
rails.on_segment = function(line, job)
  local player = line.tool and game.get_player(line.tool)
  local T = player and tool(player.index)
  if not (T and T.pending == line.id) then
    -- (a segment of a tool undone while planning, or of a closed tool)
    if line.state == "failed" and line.tool then storage.rails.lines[line.id] = nil end
    return
  end
  T.pending = nil
  local target = T.target or {}
  if line.state == "failed" then
    local why = tostring(line.reason)
    local text
    if string.sub(why, 1, 5) == "land-" then
      text = {"rts.territory-refused-" .. string.sub(why, 6), {"entity-name.straight-rail"}}
    else
      text = {"rts.railtool-refused", {"rts.rails-why-" .. why}}
    end
    flying(player, text)
    util.log("railtool: segment #%d refused (%s) player=%d", line.id, why, player.index)
    storage.rails.lines[line.id] = nil
    panel(player)
    return
  end
  T.segments[#T.segments + 1] = line.id
  local last = line.pieces[#line.pieces]
  T.head = {kind = "state", x = last.gx, y = last.gy, d = last.gd, l = last.l or 0, line = line.id}
  if target.rail then T.head = {kind = "rail", rail = target.rail} end -- (a join: the next segment starts from it)
  T.bill_rails = (T.bill_rails or 0) + (line.bill and line.bill.rails or 0)
  mark(player, T, {x = last.gx, y = last.gy}, {r = 0.3, g = 0.7, b = 1})
  flying(player, {"rts.railtool-bill", line.missing or 0, line.bill and line.bill.rails or 0,
    line.bill and line.bill.signals or 0, line.reused or 0})
  util.log("railtool: segment #%d planned: %d pieces (%d new, %d of own track), bill %d rails player=%d", line.id,
    #line.pieces, line.missing or 0, line.reused or 0, line.bill and line.bill.rails or 0, player.index)
  panel(player)
end

--- Undo the last segment: its ghosts and supports not built yet go, built pieces stay; the head goes back.
function railtool.undo(player)
  local T = tool(player.index)
  if not T then return false end
  if T.pending then
    local R = storage.rails
    if R.jobs[T.pending] then R.jobs[T.pending].phase = "failed" end
    T.pending = nil
    return true
  end
  local id = table.remove(T.segments)
  if not id then
    if T.head then
      T.head, T.origin = nil, nil
      clear_marks(T)
      panel(player)
      return true
    end
    return false
  end
  local gone = storage.rails.lines[id]
  T.bill_rails = math.max(0, (T.bill_rails or 0) - (gone and gone.bill and gone.bill.rails or 0))
  local ok, n = rails.remove_manual_line(id)
  local prev = T.segments[#T.segments]
  local line = prev and storage.rails.lines[prev]
  local last = line and line.pieces and line.pieces[#line.pieces]
  if last then
    T.head = {kind = "state", x = last.gx, y = last.gy, d = last.gd, l = last.l or 0, line = prev}
  else
    T.head = T.origin -- (the first segment went: the next click plans from the start again)
  end
  flying(player, {"rts.railtool-undone", n or 0})
  util.log("railtool: segment #%d undone (%d ghosts removed) player=%d", id, n or 0, player.index)
  panel(player)
  return ok
end

-- The player whose tool is open, or nil (the hooks also run for script orders: player_index 0 or nil).
local function tool_player(player_index)
  if not (player_index and player_index >= 1 and tool(player_index)) then return nil end
  return game.get_player(player_index)
end

-- Left click (selection.lua's area hook): a click with the tool open is a waypoint; a drag is ignored.
selection.area_hook = function(player_index, area, entities, surface)
  local player = tool_player(player_index)
  if not player then return false end
  local lt, rb = area.left_top, area.right_bottom
  if rb.x - lt.x > 1.5 or rb.y - lt.y > 1.5 then return true end
  railtool.click(player, {x = (lt.x + rb.x) / 2, y = (lt.y + rb.y) / 2})
  return true
end

-- Right click: undo (first of orders.lua's right-click hooks while the tool is open).
orders.on_right_click(function(player_index, position, entities, alt)
  local player = tool_player(player_index)
  if not player then return nil end
  local ok = railtool.undo(player)
  return "rail-undo", ok and 1 or 0
end, true)

events.on("rts-rail-undo", function(e)
  local player = tool_player(e.player_index)
  if player then railtool.undo(player) end
end)

events.on("rts-clear-cursor", function(e)
  local player = tool_player(e.player_index)
  if player then railtool.close(player, "Q") end
end)

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local player = game.get_player(e.player_index)
  local action = el.tags and el.tags.rts_railtool
  if action == "undo" then railtool.undo(player)
  elseif action == "done" then railtool.close(player, "done") end
end)

function railtool.init()
  S()
  for index, T in pairs(S().tools) do
    local player = game.get_player(index)
    if not (player and player.connected) then S().tools[index] = nil end
  end
end

return railtool
