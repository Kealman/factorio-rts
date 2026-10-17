-- Research panel (docs/PHASE4.md section 7 "tech panel"; docs/qa/phase4-research-notes.md "Research panel").
-- T (custom input rts-tech) toggles a screen frame, independent of the HUD: the current research with its progress,
-- labs, kits in the network, then the technologies by tier with cost, status and a Research / Cancel button.
-- Escape closes it (player.opened). While open it refreshes every REFRESH ticks, updating captions in place.
--
-- Owns util.pstorage(i).techgui = {frame, rows = {[tech] = {status, button, key}}, current, bar, labs, kits}.
-- Element names start with "rts_tech_"; clicks carry tags.rts_tech = "research" | "cancel" | "close".
local util = require("scripts.util")
local events = require("scripts.events")
local research = require("scripts.research")
local economy = require("scripts.economy")

local techgui = {}
-- Phase 5 M3 age3 (scripts/sinks.lua sets these): extend(player, g, current_row) adds the research Rush button,
-- extend_refresh(player, g) updates it
techgui.extend, techgui.extend_refresh = nil, nil

techgui.FRAME = "rts_tech_frame"
techgui.REFRESH = 30
local PREFIX = "rts_tech_"
local NAME_WIDTH, COST_WIDTH, STATUS_WIDTH, BUTTON_WIDTH = 190, 56, 104, 84
local ICON = 28

local STATUS_COLOR = {
  done = {r = 0.5, g = 0.9, b = 0.5},
  researching = {r = 1, g = 0.82, b = 0.3},
  queued = {r = 0.9, g = 0.9, b = 0.6},
  available = {r = 1, g = 1, b = 1},
  locked = {r = 0.6, g = 0.6, b = 0.6},
  disabled = {r = 0.6, g = 0.6, b = 0.6},
}

local function gui_state(player) return util.pstorage(player.index) end

function techgui.is_open(player)
  local f = player.gui.screen[techgui.FRAME]
  return f ~= nil and f.valid
end

function techgui.close(player)
  local f = player.gui.screen[techgui.FRAME]
  if f then f.destroy() end
  gui_state(player).techgui = nil
end

local function requires_text(force, entry)
  local parts = {""}
  for name in pairs(entry.prerequisites or {}) do
    local tech = force.technologies[name]
    if #parts > 1 then parts[#parts + 1] = ", " end
    parts[#parts + 1] = tech and tech.localised_name or name
  end
  return parts
end

local function row_tooltip(force, entry)
  local tech = force.technologies[entry.name]
  local tip = {"", tech.localised_description}
  if next(entry.prerequisites or {}) then
    tip[#tip + 1] = "\n"
    tip[#tip + 1] = {"rts.tech-requires", requires_text(force, entry)}
  end
  return tip
end

local function add_row(tbl, force, entry, rows)
  local tech = force.technologies[entry.name]
  local tip = row_tooltip(force, entry)
  local icon = tbl.add({type = "sprite", sprite = "technology/" .. entry.name, tooltip = tip})
  icon.style.width = ICON
  icon.style.height = ICON
  icon.style.stretch_image_to_widget_size = true
  local name = tbl.add({type = "label", caption = tech.localised_name, tooltip = tip})
  name.style.width = NAME_WIDTH
  local cost = tbl.add({type = "label", caption = string.format("[item=%s] %d", entry.kit, entry.count),
                        tooltip = {"rts.tech-cost-tooltip", entry.count, 10}})
  cost.style.width = COST_WIDTH
  local status = tbl.add({type = "label", caption = ""})
  status.style.width = STATUS_WIDTH
  local button = tbl.add({type = "button", name = PREFIX .. "btn_" .. entry.name, caption = {"rts.tech-research"},
                          tags = {rts_tech = "research", tech = entry.name}})
  button.style.width = BUTTON_WIDTH
  button.style.height = ICON
  button.style.padding = 0
  rows[entry.name] = {status = status, button = button}
end

--- Build (or rebuild) the panel for a player.
function techgui.open(player)
  techgui.close(player)
  research.sync()
  local force = player.force
  local frame = player.gui.screen.add({type = "frame", name = techgui.FRAME, direction = "vertical"})
  frame.auto_center = true
  local bar = frame.add({type = "flow", direction = "horizontal"})
  bar.drag_target = frame
  bar.add({type = "label", caption = {"rts.tech-title"}, style = "frame_title", ignored_by_interaction = true})
  local drag = bar.add({type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.style.right_margin = 4
  bar.add({type = "sprite-button", name = PREFIX .. "close", style = "frame_action_button", sprite = "utility/close",
           tooltip = {"rts.tech-close-tooltip"}, tags = {rts_tech = "close"}})

  local top = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  top.style.horizontally_stretchable = true
  local cur_flow = top.add({type = "flow", direction = "horizontal"})
  cur_flow.style.vertical_align = "center"
  local current = cur_flow.add({type = "label", caption = ""})
  current.style.width = 330
  local progress = cur_flow.add({type = "progressbar", value = 0})
  progress.style.horizontally_stretchable = true
  local info = top.add({type = "flow", direction = "horizontal"})
  local labs = info.add({type = "label", caption = ""})
  labs.style.width = 330
  local kits = info.add({type = "label", caption = ""})
  local hint = top.add({type = "label", caption = {"rts.tech-hint"}})
  hint.style.font_color = {r = 0.7, g = 0.7, b = 0.7}

  local cols = frame.add({type = "flow", direction = "horizontal"})
  cols.style.horizontal_spacing = 8
  cols.style.top_margin = 8
  local rows = {}
  local tables = {}
  for tier = 1, research.max_tier() do -- Phase 5 E1: Nation mode adds tier 3 (Age II, industrial kits)
    local col = cols.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
    col.style.vertically_stretchable = true
    local head = col.add({type = "label", caption = {"rts.tech-tier-" .. tier}, style = "caption_label"})
    head.style.bottom_margin = 4
    local tbl = col.add({type = "table", column_count = 5})
    tbl.style.horizontal_spacing = 6
    tbl.style.vertical_spacing = 4
    tables[tier] = tbl
  end
  for _, entry in ipairs(research.list()) do add_row(tables[entry.tier], force, entry, rows) end

  gui_state(player).techgui = {frame = frame, rows = rows, current = current, bar = progress, labs = labs,
                               kits = kits}
  if techgui.extend then techgui.extend(player, gui_state(player).techgui, cur_flow) end -- Phase 5 M3 age3
  player.opened = frame
  techgui.refresh(player)
  util.log("techgui: opened by player %d (%s): %d technologies", player.index, force.name, table_size(rows))
  return frame
end

function techgui.toggle(player)
  if techgui.is_open(player) then
    techgui.close(player)
    util.log("techgui: closed by player %d", player.index)
  else
    techgui.open(player)
  end
end

--- Update captions of an open panel in place.
function techgui.refresh(player)
  local g = gui_state(player).techgui
  if not (g and g.frame and g.frame.valid) then return end
  local force = player.force
  local queue_set = {}
  for _, t in ipairs(force.research_queue or {}) do queue_set[t.name] = true end
  local cur = research.current(force.name)
  if cur then
    local tech = force.technologies[cur.name]
    g.current.caption = {"rts.tech-current", tech.localised_name, math.floor(cur.progress * 100)}
    g.bar.value = cur.progress
  else
    g.current.caption = {"rts.tech-none"}
    g.bar.value = 0
  end
  local n, working = research.lab_counts(force.name)
  g.labs.caption = {"rts.tech-labs", n, working}
  local items = economy.snapshot(force.name).items or {}
  g.kits.caption = {"rts.tech-kits", items["rts-science-basic"] or 0, items["rts-science-advanced"] or 0}
  for name, row in pairs(g.rows) do
    local status = research.status(force.name, name, queue_set)
    local pct = status == "researching" and cur and math.floor(cur.progress * 100) or 0
    local key = status .. ":" .. pct
    if row.key ~= key and row.status.valid then
      row.key = key
      row.status.caption = status == "researching" and {"rts.tech-status-researching", pct}
        or {"rts.tech-status-" .. status}
      row.status.style.font_color = STATUS_COLOR[status] or STATUS_COLOR.locked
      local cancel = status == "researching" or status == "queued"
      row.button.caption = cancel and {"rts.tech-cancel"} or {"rts.tech-research"}
      row.button.tags = {rts_tech = cancel and "cancel" or "research", tech = name}
      row.button.enabled = cancel or status == "available"
    end
  end
  if techgui.extend_refresh then techgui.extend_refresh(player, g) end -- Phase 5 M3 age3
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
events.on("rts-tech", function(e)
  local player = game.get_player(e.player_index)
  util.log("techgui: rts-tech (T) player=%d", player.index)
  techgui.toggle(player)
end)

local function on_click(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local action = el.tags and el.tags.rts_tech
  local player = game.get_player(e.player_index)
  if action == "close" then
    techgui.close(player)
    util.log("techgui: closed by player %d (button)", player.index)
    return
  elseif action == "research" then
    research.queue(player.force.name, el.tags.tech)
  elseif action == "cancel" then
    research.cancel(player.force.name, el.tags.tech)
  else
    return
  end
  techgui.refresh(player)
end
techgui.on_click = on_click -- the GUI probe clicks through this path

events.on(defines.events.on_gui_click, on_click)

events.on(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and el.name == techgui.FRAME then
    local player = game.get_player(e.player_index)
    techgui.close(player)
    util.log("techgui: closed by player %d (Escape)", player.index)
  end
end)

events.on_nth_tick(techgui.REFRESH, function()
  for _, player in pairs(game.connected_players) do
    if techgui.is_open(player) then techgui.refresh(player) end
  end
end)

return techgui
