-- HUD: four areas in player.gui.screen.
--   bottom-left   selection panel. With units selected: count per kind, average health, current order, four
--                 command buttons, control-group indicators 1-5. With an own building selected (Phase 2): its
--                 name and health, then per kind: barracks / factory recipe buttons + pause, production progress,
--                 counters and the rally point; Command Center bots and power; turret ammo; others their status.
--   bottom-right  build menu (Phase 2): one slot button per placeable item with the count in the logistic network;
--                 a click puts a ghost of the item in the cursor (cursor.give_ghost). B shows / hides it.
--   top-centre    match strip: timer and own vs enemy unit counts; the resource row (iron, copper, steel, stone,
--                 magazines, power, bots from economy.snapshot); a message line (attack-move armed, build mode,
--                 enemy waves, match result)
--   top-right     minimap of the arena (directly on `screen`, over a decorative frame); a click jumps the
--                 camera there (camera.jump_to)
--
-- Owns storage.players[i].hud = {panel, strip, minimap_frame, minimap, build (LuaGuiElement), el = {...},
--   groups = {...}, res = {...}, build_buttons = {[item] = button}, recipe_buttons = {[recipe or ""] = button},
--   bld_un = unit number the recipe buttons were built for},
-- storage.players[i].hud_prefs = {build_hidden} (survives HUD rebuilds), storage.players[i].hud_resource_log
-- = {line, tick} (last "hud resources" QA line)
-- and storage.hud = {wave_seen, wave_tick, ended_tick} (match-event tracking shared by all players).
-- Reads storage.players[i].selection / .groups / .building (selection.lua), storage.units (units.lua),
-- storage.buildings (buildings.lua) and storage.match (match.lua); never writes them.
--
-- selection.lua / orders.lua / debug.lua are looked up at call time through package.loaded, never require()d
-- here: require() is not allowed inside event handlers, and a top-level require would create a require cycle
-- (they call hud.refresh) or change the event-handler order (debug.lua loads after the HUD).
-- buildings, production, economy, match and cursor are required normally: control.lua loads them earlier.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local camera = require("scripts.camera")
local match = require("scripts.match")
local cursor = require("scripts.cursor")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local economy = require("scripts.economy")

local hud = {}

local PLAYER, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE

-- Dev only. The HUD self-test steps are camera self-test steps (camera.add_selftest_step), so they run
-- only while camera.selftest_enabled() is true: off by default, `/rts-selftest on` turns it on and restarts
-- the steps for connected players. Ticks are counted from the player's camera setup:
-- camera.lua checks the steps every 30 ticks and runs every due step in that sweep, and a screenshot is rendered
-- at the end of its tick, so a state that a screenshot must show is set at least one sweep earlier.
--   390   build menu click path for rts-barracks (ghost in the cursor); 420 screenshot (build mode)
--   450   build_from_cursor: one barracks ghost next to the CC, plus a factory ghost by script (robots build both)
--   480   clear the cursor (what Q does); 510 logs that the RTS cursor is back
--   510   arms attack-move through the button path; 540 screenshot (red button, prompt); 570 disarms
--   540   presses "Select all" through the button path and assigns control group 1
--   600   screenshot rts-hud-<tick>.png
--   660   synthetic minimap click at the enemy army (the camera jumps there)
--   720   screenshot
--   780   camera home
--   820   click-selects the Command Center; 840 screenshot (CC panel, build menu, resource strip)
--   860   click-selects the barracks, walker-kit recipe through the button path, rally point through the
--         right-click path (camera.lua's screenshot at 900 shows the barracks panel and the flag)
--   960   click-selects the factory (placed as a ghost at 450), extractor recipe, screenshot (11 recipe buttons)
--   3000  screenshot, then the "RTS_HUD_DONE" marker
-- HUD_CALIBRATE (a load-time constant): at setup + 180 adds chart tags A, B, C at (-64,-64), (64,-64),
-- (-64,64) and O at (0,0), to measure the minimap scale from a screenshot (docs/qa/phase1-hud-notes.md).
local HUD_CALIBRATE = false

local REFRESH_PERIOD = 30          -- ticks; full refresh (counts, resources, dead units, timer)
local BUILDING_REFRESH_PERIOD = 10 -- ticks; building panel only (production progress), while one is selected
local WAVE_ALERT_TICKS = 10 * 60   -- how long "wave N is attacking" stays on the message line
local RESOURCE_LOG_TICKS = 5 * 60  -- the "hud resources" QA line is written at most this often (on change)

-- Layout, in GUI units (multiplied by player.display_scale on screen).
local MARGIN = 8
local PANEL_WIDTH, PANEL_HEIGHT = 420, 140
local STRIP_WIDTH, STRIP_HEIGHT = 600, 96
local LINE_WIDTH = PANEL_WIDTH - 16 -- inside the frame's padding
local LINE1_WITH_BAR = 270         -- first status line when the 120-wide progress bar shares its row
local BUILD_COLUMNS = 6
local BUILD_WIDTH, BUILD_HEIGHT = 272, 122
local MINIMAP_SIZE = 220
local MINIMAP_PADDING = 4          -- rim of the decorative frame drawn behind the minimap
local MINIMAP_FRAME_SIZE = MINIMAP_SIZE + 2 * MINIMAP_PADDING

-- Minimap scale. MINIMAP_PX_PER_TILE_AT_ZOOM_1 is GUI pixels per tile at minimap zoom 1, measured from
-- screenshots (docs/qa/phase1-hud-notes.md). The zoom is chosen so the 160-tile arena plus a rim fits.
local ARENA_HALF = 80
local MINIMAP_CENTER = {x = 0, y = 0}
local MINIMAP_VIEW_TILES = 2 * ARENA_HALF + 16
local MINIMAP_PX_PER_TILE_AT_ZOOM_1 = 1.0
local MINIMAP_ZOOM = MINIMAP_SIZE / (MINIMAP_VIEW_TILES * MINIMAP_PX_PER_TILE_AT_ZOOM_1) -- 1.25

local NAMES = {panel = "rts_hud_panel", strip = "rts_hud_strip", minimap_frame = "rts_hud_minimap_frame",
               minimap = "rts_hud_minimap", build = "rts_hud_build"}
local PREFIX = "rts_hud_"          -- every clickable HUD element's name starts with this

local KIND_NAMES = {walker = "Walker", heavy = "Heavy"}
local KIND_RANK = {walker = 1, heavy = 2}
local ORDER_NAMES = {idle = "Idle", move = "Move", attack = "Attack", attack_move = "Attack-move", hold = "Hold"}
local BUILDING_NAMES = {cc = "Command Center", barracks = "Barracks", factory = "Factory", turret = "Turret",
                        extractor = "Extractor", smelter = "Smelter", stockpile = "Stockpile", solar = "Solar array"}

local COLOR = {
  white = {1, 1, 1},
  dim = {0.72, 0.72, 0.72},
  yellow = {1, 0.85, 0.3},
  red = {1, 0.42, 0.36},
  green = {0.5, 1, 0.5},
  own = {0.5, 0.72, 1},
  enemy = {1, 0.5, 0.45},
}

-- Command buttons. Each calls the first of module[fns[i]](player_index) that exists at click time.
local COMMANDS = {
  {action = "attack_move", caption = "Attack-move", key = "F", module = "scripts.orders",
   fns = {"arm_attack_move"},
   tooltip = "Attack-move: the next right click sends the selection there, fighting every enemy on the way."},
  {action = "stop", caption = "Stop", key = "X", module = "scripts.orders", fns = {"stop"},
   tooltip = "Stop: cancel the current orders. Units still return fire."},
  {action = "hold", caption = "Hold", key = "H", module = "scripts.orders", fns = {"hold"},
   tooltip = "Hold position: stay put and fire at enemies in range."},
  {action = "select_all", caption = "Select all", key = "Ctrl+A", module = "scripts.selection", fns = {"select_all"},
   tooltip = "Select your whole army."},
}
local COMMAND_BY_ACTION = {}
for _, c in pairs(COMMANDS) do COMMAND_BY_ACTION[c.action] = c end
local GROUP_COUNT = 5

-- Build menu, in button order: the first BUILD_COLUMNS are the economy row, then production and defense.
-- The belt, inserter and pole are the vanilla items (docs/qa/phase2-prototypes-notes.md "Reused vanilla
-- entities"). An item without an rts recipe (the stockpile has none yet) is disabled while the network holds
-- none of it, so it only becomes usable when some was given (/rts-give rts-stockpile 2) or a recipe is added.
local BUILD_ITEMS = {
  "rts-extractor", "rts-smelter", "rts-solar-array", "transport-belt", "fast-inserter", "medium-electric-pole",
  "rts-factory", "rts-barracks", "rts-turret", "rts-stockpile",
}
local RTS_CATEGORIES = {["rts-buildings"] = true, ["rts-units"] = true}

-- Top-strip resources: economy.snapshot field, icon, tooltip.
local RESOURCES = {
  {key = "iron", sprite = "item/iron-plate", tooltip = "Iron plates in your logistic network"},
  {key = "copper", sprite = "item/copper-plate", tooltip = "Copper plates in your logistic network"},
  {key = "steel", sprite = "item/steel-plate", tooltip = "Steel plates in your logistic network (smelters make them from iron plates)"},
  {key = "stone", sprite = "item/stone", tooltip = "Stone in your logistic network (the smelter recipe needs it)"},
  {key = "magazines", sprite = "item/firearm-magazine", tooltip = "Firearm magazines in your logistic network (turret ammo)"},
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- The first of `fn_names` exported by an already-loaded module, or nil. Safe inside event handlers.
--- package.loaded is keyed by the resolved file, "__factorio-rts__/scripts/orders.lua", not by the
--- require() argument "scripts.orders" (logged on 2.0.77); both keys are tried.
local function optional_fn(module_name, fn_names)
  local loaded = package and package.loaded
  if not loaded then return nil end
  local mod = loaded["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"]
    or loaded[module_name]
  if type(mod) ~= "table" then return nil end
  for _, name in ipairs(fn_names) do
    if type(mod[name]) == "function" then return mod[name] end
  end
  return nil
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function count_force(force_name)
  if not storage.units then return 0 end
  return units.count(force_name)
end

local function fmt_count(n)
  n = math.floor(n or 0)
  if n >= 100000 then return string.format("%dk", math.floor(n / 1000)) end
  if n >= 10000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

local function fmt_seconds(s)
  if s == math.floor(s) then return string.format("%d s", s) end
  return string.format("%.1f s", s)
end

--- The live registry record of a unit, without side effects (units.get would drop stale records and
--- fire on_removed callbacks while we iterate another module's set).
local function live_record(unit_number)
  local rec = storage.units and storage.units[unit_number]
  if rec and rec.entity and rec.entity.valid then return rec end
  return nil
end

--- Same for a building (buildings.get has the same side effects).
local function live_building(unit_number)
  local rec = unit_number and storage.buildings and storage.buildings[unit_number]
  if rec and rec.entity and rec.entity.valid then return rec end
  return nil
end

local function live_count(set)
  local n = 0
  if set then
    for un in pairs(set) do
      if live_record(un) then n = n + 1 end
    end
  end
  return n
end

local function pstate(player_index)
  return storage.players and storage.players[player_index]
end

local function prefs(player_index)
  local p = util.pstorage(player_index)
  p.hud_prefs = p.hud_prefs or {}
  return p.hud_prefs
end

--- The economy snapshot of a force, or nil before economy.init ran (a save from Phase 1).
local function snapshot(force_name)
  if not (storage.economy and storage.economy.cache) then return nil end
  return economy.snapshot(force_name)
end

--- The player's selected building: unit_number, record (nil when none).
local function selected_building(player)
  local p = pstate(player.index)
  local un = p and p.building
  local rec = live_building(un)
  if rec then return un, rec end
  return nil, nil
end

--- The player's HUD state if all its frames are alive, else nil.
local function get_hud(player)
  local p = pstate(player.index)
  local h = p and p.hud
  if h and h.panel and h.panel.valid and h.strip and h.strip.valid and h.minimap_frame and h.minimap_frame.valid
     and h.minimap and h.minimap.valid and h.build and h.build.valid then
    return h
  end
  return nil
end

---------------------------------------------------------------------------
-- Recipes (derived from prototypes only, so the caches are identical on every client)
---------------------------------------------------------------------------
local recipe_by_item     -- [item name] = LuaRecipePrototype of the rts recipe that makes it
local recipes_by_machine = {} -- [entity name] = {LuaRecipePrototype...} sorted by order

local function recipe_for(item)
  if not recipe_by_item then
    recipe_by_item = {}
    for _, r in pairs(prototypes.recipe) do
      local product = r.products and r.products[1]
      if RTS_CATEGORIES[r.category] and not r.parameter and product and product.type == "item"
         and not recipe_by_item[product.name] then
        recipe_by_item[product.name] = r
      end
    end
  end
  return recipe_by_item[item]
end

local function machine_recipes(entity)
  local list = recipes_by_machine[entity.name]
  if list then return list end
  list = {}
  -- Every crafting machine also lists the "parameters" category (the blueprint parameter recipes 0-9, seen in
  -- the first GUI run as ten purple buttons on the barracks): those recipes are skipped.
  local categories = entity.prototype.crafting_categories or {}
  for _, r in pairs(prototypes.recipe) do
    if categories[r.category] and not r.parameter and not r.hidden then list[#list + 1] = r end
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  recipes_by_machine[entity.name] = list
  return list
end

-- "[item=iron-plate] 10  [item=copper-plate] 2"
local function cost_text(recipe)
  local parts = {}
  for _, ing in ipairs(recipe.ingredients) do
    parts[#parts + 1] = string.format("[%s=%s] %d", ing.type, ing.name, ing.amount)
  end
  return table.concat(parts, "  ")
end

local function product_amount(recipe)
  local product = recipe.products and recipe.products[1]
  return product and (product.amount or product.amount_max) or 1
end

local function build_items()
  local list = {}
  for _, item in ipairs(BUILD_ITEMS) do
    if prototypes.item[item] then list[#list + 1] = item end
  end
  return list
end

local function build_tooltip(item, in_network)
  local proto = prototypes.item[item]
  local recipe = recipe_for(item)
  local how = recipe and string.format("Factory recipe: %s gives %d in %s.", cost_text(recipe), product_amount(recipe),
    fmt_seconds(recipe.energy)) or "No factory recipe: usable only while the network holds some."
  return {"", "[font=default-bold]", proto.localised_name, "[/font]\n",
          string.format("In your network: %d. %s\n", in_network, how),
          "Click, then left-click the map to place ghosts; robots build them from the network.\n",
          "R rotates. Q or right-click ends placing."}
end

local function recipe_tooltip(recipe)
  return {"", "[font=default-bold]", recipe.localised_name, "[/font]\n",
          string.format("Cost: %s. Time: %s.", cost_text(recipe), fmt_seconds(recipe.energy))}
end

---------------------------------------------------------------------------
-- Minimap maths
--
-- Screen (display) coordinates are physical pixels, the same space as GuiLocation and
-- cursor_display_location. GUI sizes are scaled by player.display_scale. The minimap element sits
-- directly in player.gui.screen, so its `location` is its own top-left corner (inside a frame, the
-- content offset did not match the frame's padding: ~8.7 GUI px measured with padding 4). It shows
-- `zoom * K * scale` physical pixels per tile around `position` (K = MINIMAP_PX_PER_TILE_AT_ZOOM_1).
---------------------------------------------------------------------------
local function minimap_geometry(player, h)
  local s = player.display_scale
  local loc = h.minimap.location or {x = 0, y = 0}
  local size = MINIMAP_SIZE * s
  local cx = (loc.x or loc[1]) + size / 2
  local cy = (loc.y or loc[2]) + size / 2
  local ppt = MINIMAP_PX_PER_TILE_AT_ZOOM_1 * h.minimap.zoom * s -- physical pixels per tile
  return cx, cy, ppt, size
end

--- World position under a display location on the minimap.
local function minimap_to_world(player, h, display)
  local cx, cy, ppt = minimap_geometry(player, h)
  local center = h.minimap.position
  local dx, dy = (display.x or display[1]) - cx, (display.y or display[2]) - cy
  return {x = center.x + dx / ppt, y = center.y + dy / ppt}, dx, dy
end

--- Display location of a world position on the minimap (inverse of minimap_to_world).
local function world_to_minimap(player, h, position)
  local cx, cy, ppt = minimap_geometry(player, h)
  local center = h.minimap.position
  local x, y = util.xy(position)
  return {x = math.floor(cx + (x - center.x) * ppt + 0.5), y = math.floor(cy + (y - center.y) * ppt + 0.5)}
end

---------------------------------------------------------------------------
-- Building and placement
---------------------------------------------------------------------------
local function px(gui_units, s) return math.floor(gui_units * s + 0.5) end

local function place(player, h)
  local res, s = player.display_resolution, player.display_scale
  local m = px(MARGIN, s)
  local pad = px(MINIMAP_PADDING, s)
  local mx = res.width - px(MINIMAP_SIZE, s) - pad - m
  h.minimap.location = {mx, m + pad}
  h.minimap_frame.location = {mx - pad, m}
  h.panel.location = {m, res.height - px(PANEL_HEIGHT, s) - m}
  h.build.location = {res.width - px(BUILD_WIDTH, s) - m, res.height - px(BUILD_HEIGHT, s) - m}
  -- Centred, but never under the minimap (at large UI scales on narrow windows the centred strip would reach it).
  local sw = px(STRIP_WIDTH, s)
  local sx = math.floor((res.width - sw) / 2 + 0.5)
  sx = math.max(m, math.min(sx, mx - pad - m - sw))
  h.strip.location = {sx, m}
  util.log("hud: layout player=%d display %dx%d scale %.2f: panel (%d, %d) %dx%d, build (%d, %d) %dx%d, "
    .. "strip (%d, %d) %dx%d, minimap (%d, %d) %dx%d", player.index, res.width, res.height, s,
    m, res.height - px(PANEL_HEIGHT, s) - m, px(PANEL_WIDTH, s), px(PANEL_HEIGHT, s),
    res.width - px(BUILD_WIDTH, s) - m, res.height - px(BUILD_HEIGHT, s) - m, px(BUILD_WIDTH, s), px(BUILD_HEIGHT, s),
    sx, m, sw, px(STRIP_HEIGHT, s), mx, m + pad, px(MINIMAP_SIZE, s), px(MINIMAP_SIZE, s))
end

local function add_filler(parent)
  return parent.add({type = "empty-widget", style = "rts_hud_filler"})
end

local function vflow(parent)
  local flow = parent.add({type = "flow", direction = "vertical"})
  flow.style.vertical_spacing = 4
  return flow
end

local function build_unit_page(panel, h)
  local el = h.el
  local page = vflow(panel)
  el.unit_page = page

  local header = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.sel_count = header.add({type = "label", style = "rts_hud_heading_label"})
  add_filler(header)
  el.health = header.add({type = "label", style = "rts_hud_mono_label", tooltip = "Average health of the selection"})
  el.order = header.add({type = "label", style = "rts_hud_label", tooltip = "Current order of the selection"})

  el.kinds = page.add({type = "label", style = "rts_hud_label"})

  local commands = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  for _, c in ipairs(COMMANDS) do
    el["cmd_" .. c.action] = commands.add({
      type = "button", name = PREFIX .. "cmd_" .. c.action, style = "rts_hud_button",
      caption = string.format("%s [%s]", c.caption, c.key),
      tooltip = string.format("%s (%s)\n%s", c.caption, c.key, c.tooltip),
      tags = {rts_hud = c.action}})
  end

  local groups = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  groups.add({type = "label", style = "rts_hud_dim_label", caption = "Groups"})
  for n = 1, GROUP_COUNT do
    h.groups[n] = groups.add({type = "button", name = PREFIX .. "group_" .. n, style = "rts_hud_group_button",
                              caption = tostring(n), tags = {rts_hud = "group", group = n}})
  end
  page.add({type = "label", style = "rts_hud_dim_label",
            caption = "Right-click: move or attack. Shift + right-drag: attack-move. Space: home."})
end

local function build_building_page(panel, h)
  local el = h.el
  local page = vflow(panel)
  page.visible = false
  el.bld_page = page

  local header = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.b_name = header.add({type = "label", style = "rts_hud_heading_label"})
  add_filler(header)
  el.b_hp = header.add({type = "label", style = "rts_hud_mono_label", tooltip = "Health"})

  local row = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.b_line1 = row.add({type = "label", style = "rts_hud_label"})
  el.b_line1.style.maximal_width = LINE1_WITH_BAR
  add_filler(row)
  el.b_progress = row.add({type = "progressbar", style = "rts_hud_progressbar", value = 0,
                           tooltip = "Progress of the item in production"})

  el.b_buttons = page.add({type = "flow", direction = "horizontal"})
  el.b_buttons.style.horizontal_spacing = 2
  el.b_line2 = page.add({type = "label", style = "rts_hud_label"})
  el.b_line2.style.maximal_width = LINE_WIDTH
  el.b_line3 = page.add({type = "label", style = "rts_hud_dim_label"})
  el.b_line3.style.maximal_width = LINE_WIDTH
end

local function build_panel(screen, h)
  local panel = screen.add({type = "frame", name = NAMES.panel, direction = "vertical", style = "rts_hud_frame"})
  panel.style.width = PANEL_WIDTH
  panel.style.height = PANEL_HEIGHT
  h.panel = panel
  build_unit_page(panel, h)
  build_building_page(panel, h)
end

local function resource_pair(row, sprite, tooltip)
  local pair = row.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  pair.style.horizontal_spacing = 3
  pair.add({type = "sprite", sprite = sprite, style = "rts_hud_icon", tooltip = tooltip})
  return pair.add({type = "label", style = "rts_hud_mono_label", caption = "-", tooltip = tooltip}), pair
end

local function build_strip(screen, h)
  local strip = screen.add({type = "frame", name = NAMES.strip, direction = "vertical", style = "rts_hud_frame"})
  strip.style.width = STRIP_WIDTH
  strip.style.height = STRIP_HEIGHT
  h.strip = strip
  local el = h.el
  local row = strip.add({type = "flow", direction = "horizontal", style = "rts_hud_centered_row"})
  el.timer = row.add({type = "label", style = "rts_hud_timer_label", caption = "--:--", tooltip = "Match time"})
  el.own = row.add({type = "label", style = "rts_hud_mono_label", tooltip = "Your units"})
  el.own.style.font_color = COLOR.own
  row.add({type = "label", style = "rts_hud_dim_label", caption = "vs"})
  el.enemy = row.add({type = "label", style = "rts_hud_mono_label", tooltip = "Enemy units"})
  el.enemy.style.font_color = COLOR.enemy

  local res = strip.add({type = "flow", direction = "horizontal", style = "rts_hud_centered_row"})
  h.res = {}
  for _, r in ipairs(RESOURCES) do h.res[r.key] = resource_pair(res, r.sprite, r.tooltip) end
  local power_tip = "Power: used / available (4 MW per Command Center plus 400 kW per solar array), then the "
    .. "satisfaction of your machines. Below 100% everything works slower."
  local power, pair = resource_pair(res, "tooltip-category-electricity", power_tip) -- core SpritePrototype
  h.res.power = power
  h.res.power_sat = pair.add({type = "label", style = "rts_hud_mono_label", caption = "", tooltip = power_tip})
  h.res.bots = resource_pair(res, "item/construction-robot",
    "Robots idle / total (construction + logistic). Construction robots build your ghosts.")

  local message_row = strip.add({type = "flow", direction = "horizontal", style = "rts_hud_centered_row"})
  el.message = message_row.add({type = "label", style = "rts_hud_message_label"})
end

local function build_build_menu(screen, h)
  local frame = screen.add({type = "frame", name = NAMES.build, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = BUILD_WIDTH
  frame.style.height = BUILD_HEIGHT
  h.build = frame
  local header = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  header.add({type = "label", style = "rts_hud_heading_label", caption = "Build [B]",
              tooltip = "Click a building, then left-click the map to place ghosts. Robots from your Command "
                .. "Center build them from the network. B hides this menu."})
  add_filler(header)
  header.add({type = "label", style = "rts_hud_dim_label", caption = "Q / right-click: done"})
  local grid = frame.add({type = "table", column_count = BUILD_COLUMNS})
  grid.style.horizontal_spacing = 2
  grid.style.vertical_spacing = 2
  h.build_buttons = {}
  for _, item in ipairs(build_items()) do
    h.build_buttons[item] = grid.add({type = "sprite-button", name = PREFIX .. "build_" .. item,
                                      style = "rts_hud_build_button", sprite = "item/" .. item,
                                      tags = {rts_hud = "build", item = item}})
  end
end

-- The minimap is a direct child of `screen` (exact location for the click maths), added after its
-- decorative frame so it is drawn on top of it.
local function build_minimap(screen, h)
  local frame = screen.add({type = "frame", name = NAMES.minimap_frame, style = "rts_hud_minimap_frame",
                            ignored_by_interaction = true})
  frame.style.width = MINIMAP_FRAME_SIZE
  frame.style.height = MINIMAP_FRAME_SIZE
  h.minimap_frame = frame
  local mm = screen.add({type = "minimap", name = NAMES.minimap, style = "rts_hud_minimap",
                         position = MINIMAP_CENTER, zoom = MINIMAP_ZOOM, surface_index = util.surface().index,
                         tags = {rts_hud = "minimap"}})
  mm.style.width = MINIMAP_SIZE
  mm.style.height = MINIMAP_SIZE
  mm.bring_to_front()
  h.minimap = mm
end

---------------------------------------------------------------------------
-- Refresh: units page
---------------------------------------------------------------------------
local function sorted_kinds(kinds)
  local list = {}
  for k in pairs(kinds) do list[#list + 1] = k end
  table.sort(list, function(a, b)
    local ra, rb = KIND_RANK[a] or 99, KIND_RANK[b] or 99
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return list
end

local function order_text(orders, n)
  local list = {}
  for o, c in pairs(orders) do list[#list + 1] = {o, c} end
  table.sort(list, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[1] < b[1]
  end)
  if #list == 0 then return "" end
  local function name(o) return ORDER_NAMES[o] or o end
  if #list == 1 then return name(list[1][1]) end
  return string.format("%s %d, %s %d%s", name(list[1][1]), list[1][2], name(list[2][1]), list[2][2],
    #list > 2 and ", ..." or "")
end

local function update_units(player, h)
  local el = h.el
  local p = pstate(player.index)
  local selection = p and p.selection
  local n, kinds, orders, health_sum, health_n = 0, {}, {}, 0, 0
  if selection then
    for un in pairs(selection) do
      local rec = live_record(un)
      if rec then
        n = n + 1
        local kind = rec.kind or "?"
        kinds[kind] = (kinds[kind] or 0) + 1
        local order = rec.order or units.IDLE
        orders[order] = (orders[order] or 0) + 1
        local ratio = rec.entity.get_health_ratio()
        if ratio then
          health_sum, health_n = health_sum + ratio, health_n + 1
        end
      end
    end
  end

  if n == 0 then
    el.sel_count.caption = "No units selected"
    el.kinds.caption = "Left-drag to select. Shift adds. Click a building to select it."
    el.kinds.style.font_color = COLOR.dim
    el.health.caption = ""
    el.order.caption = ""
    return n
  end

  el.sel_count.caption = string.format("%d %s selected", n, n == 1 and "unit" or "units")
  local parts = {}
  for _, kind in ipairs(sorted_kinds(kinds)) do
    parts[#parts + 1] = string.format("%s ×%d", KIND_NAMES[kind] or kind, kinds[kind])
  end
  el.kinds.caption = table.concat(parts, "   ")
  el.kinds.style.font_color = COLOR.white
  if health_n > 0 then
    local avg = health_sum / health_n
    el.health.caption = string.format("HP %3d%%", math.floor(avg * 100 + 0.5))
    el.health.style.font_color = avg >= 0.66 and COLOR.green or (avg >= 0.33 and COLOR.yellow or COLOR.red)
  else
    el.health.caption = ""
  end
  el.order.caption = "Order: " .. order_text(orders, n)
  return n
end

local function same_set(a, b)
  for un in pairs(a) do
    if live_record(un) and not b[un] then return false end
  end
  for un in pairs(b) do
    if live_record(un) and not a[un] then return false end
  end
  return true
end

local function update_groups(player, h)
  local p = pstate(player.index)
  local groups = p and p.groups
  local selection = p and p.selection
  for n = 1, GROUP_COUNT do
    local button = h.groups[n]
    local set = groups and groups[n]
    local count = live_count(set)
    if count > 0 then
      button.caption = string.format("%d: %d", n, count)
      button.tooltip = string.format("Control group %d: %d units.\n%d recalls it, Ctrl+%d assigns the selection.",
        n, count, n, n)
      button.toggled = selection ~= nil and next(selection) ~= nil and same_set(set, selection)
    else
      button.caption = tostring(n)
      button.tooltip = string.format("Control group %d is empty.\nCtrl+%d assigns the selection.", n, n)
      button.toggled = false
    end
    button.enabled = count > 0
  end
end

local function set_style(element, style)
  if element.style.name ~= style then element.style = style end
end

local function update_commands(player, h)
  local is_armed = optional_fn("scripts.orders", {"is_armed"})
  local armed = is_armed ~= nil and is_armed(player.index) == true
  local button = h.el.cmd_attack_move
  -- Not `toggled`: a toggled button draws its selected (orange) graphics over any style, which looked like the
  -- active control-group button. The red style alone is the pressed state.
  button.toggled = false
  set_style(button, armed and "rts_hud_button_armed" or "rts_hud_button")
end

---------------------------------------------------------------------------
-- Refresh: building page (Phase 2)
---------------------------------------------------------------------------
local function rebuild_recipe_buttons(player, h, un, rec)
  local flow = h.el.b_buttons
  flow.clear()
  h.recipe_buttons = {}
  h.bld_un = un
  if rec.kind ~= "barracks" and rec.kind ~= "factory" then
    flow.visible = false
    return
  end
  flow.visible = true
  local names = {}
  for _, r in ipairs(machine_recipes(rec.entity)) do
    h.recipe_buttons[r.name] = flow.add({type = "sprite-button", name = PREFIX .. "recipe_" .. r.name,
      style = "rts_hud_recipe_button", sprite = "recipe/" .. r.name, tooltip = recipe_tooltip(r),
      tags = {rts_hud = "recipe", recipe = r.name}})
    names[#names + 1] = r.name
  end
  -- QA log line: the button order, left to right ("hud: recipe buttons barracks#N: rts-walker-kit ... pause")
  util.log("hud: recipe buttons %s#%d player=%d: %s pause", rec.kind, un, player.index, table.concat(names, " "))
  h.recipe_buttons[""] = flow.add({type = "sprite-button", name = PREFIX .. "recipe_pause",
    style = "rts_hud_recipe_button", sprite = "utility/pause",
    tooltip = "Pause: clear the recipe. Production stops; loaded ingredients go back to the network.",
    tags = {rts_hud = "recipe", recipe = ""}})
end

-- "waiting for [item=iron-plate] [item=copper-plate]" from production's pull state.
local function state_text(state)
  if not state or state == "supplied" then return "running" end
  local short = string.match(state, "^starved: (.+)$")
  if short then
    local icons = {}
    for name in string.gmatch(short, "[^,]+") do icons[#icons + 1] = "[item=" .. name .. "]" end
    return "waiting for " .. table.concat(icons, " ")
  end
  if state == "no network" then return "outside the logistic network" end
  return state
end

local function status_name(entity)
  local status = entity.status
  if not status then return "-" end
  return (string.gsub(util.define_name(defines.entity_status, status), "_", " "))
end

local function update_producer(player, h, un, rec)
  local el = h.el
  local st = production.status(un) or {}
  local recipe = st.recipe and prototypes.recipe[st.recipe]
  if recipe then
    el.b_line1.caption = {"", "[recipe=" .. recipe.name .. "] ", recipe.localised_name, ": ", state_text(st.state)}
    el.b_line1.style.font_color = (st.state or ""):find("^starved") and COLOR.yellow or COLOR.white
  else
    el.b_line1.caption = "Paused: pick a recipe below."
    el.b_line1.style.font_color = COLOR.dim
  end
  el.b_progress.visible = recipe ~= nil
  el.b_line1.style.maximal_width = recipe and LINE1_WITH_BAR or LINE_WIDTH
  el.b_progress.value = math.max(0, math.min(1, st.progress or 0))
  local active = st.recipe or ""
  for name, button in pairs(h.recipe_buttons or {}) do
    if button.valid then set_style(button, name == active and "rts_hud_recipe_button_active" or "rts_hud_recipe_button") end
  end
  local stats = production.stats(rec.force)
  if rec.kind == "barracks" then
    el.b_line2.caption = string.format("Units from this barracks: %d. All barracks: %d kits, %d units (%d heavy).",
      st.spawned or 0, stats.kits, stats.walkers, stats.heavies)
    if rec.rally then
      el.b_line3.caption = string.format("Rally point %s. Right-click the ground to move it.", util.pos_str(rec.rally))
    else
      el.b_line3.caption = "No rally point: new units wait at the exit. Right-click the ground to set one."
    end
  else
    el.b_line2.caption = string.format("All factories: %d crafts, %d items moved into the network.",
      stats.buildings, stats.items)
    el.b_line3.caption = "Finished items go to the network; the build menu counts them."
  end
end

local function update_cc(player, h, un, rec)
  local el = h.el
  local snap = snapshot(rec.force)
  el.b_progress.visible = false
  el.b_line1.style.maximal_width = LINE_WIDTH
  if not snap then
    el.b_line1.caption, el.b_line2.caption, el.b_line3.caption = "", "", ""
    return
  end
  el.b_line1.caption = string.format("Robots idle: construction %d/%d, logistic %d/%d",
    snap.construction_idle, snap.construction_total, snap.logistic_idle, snap.logistic_total)
  el.b_line1.style.font_color = COLOR.white
  el.b_line2.caption = string.format("Power: %.2f / %.2f MW used, machines at %d%%", snap.power_demand / 1e6,
    snap.power_capacity / 1e6, math.floor(snap.power_satisfaction * 100 + 0.5))
  el.b_line2.style.font_color = snap.power_satisfaction < 0.9 and COLOR.red or COLOR.white
  local proto = rec.entity.prototype
  el.b_line3.caption = string.format("Robots build ghosts within %d tiles; the network reaches %d tiles.",
    proto.construction_radius or 0, proto.logistic_radius or 0)
end

local function update_other(player, h, un, rec)
  local el = h.el
  local e = rec.entity
  el.b_progress.visible = false
  el.b_line1.style.maximal_width = LINE_WIDTH
  el.b_line1.caption = "Status: " .. status_name(e)
  el.b_line1.style.font_color = e.status == defines.entity_status.working and COLOR.white or COLOR.yellow
  el.b_line3.caption = ""
  if rec.kind == "turret" then
    local ammo = e.get_inventory(defines.inventory.turret_ammo)
    local n = ammo and ammo.get_item_count(production.AMMO) or 0
    local snap = snapshot(rec.force)
    el.b_line1.caption = string.format("Ammo: %d magazines (%s)", n, rec.feed_state or "not fed yet")
    el.b_line1.style.font_color = n > 0 and COLOR.white or COLOR.red
    el.b_line2.caption = string.format("Magazines in the network: %d. Turrets refill from it.", snap and snap.magazines or 0)
    el.b_line3.caption = "The factory makes 10 magazines from 10 iron plates."
  elseif rec.kind == "extractor" then
    local target = e.mining_target
    el.b_line2.caption = target and ("Mining: [entity=" .. target.name .. "] " .. target.name) or "Not on ore."
    el.b_line3.caption = "Put a smelter, a chest or a belt at its output. Needs a pole connection for power."
  elseif rec.kind == "smelter" then
    local recipe = e.get_recipe()
    local name = recipe and recipe.name
    if not name then
      local previous = e.previous_recipe -- RecipeIDAndQualityIDPair: name is a LuaRecipePrototype on read
      local id = previous and previous.name
      name = id and (type(id) == "string" and id or id.name)
    end
    el.b_line2.caption = name and ("Smelting: [recipe=" .. name .. "] " .. name) or "Waiting for ore."
    el.b_line3.caption = "Feed it ore by belt and inserter (or an extractor output); an inserter takes the plates out."
  elseif rec.kind == "stockpile" then
    local inv = e.get_inventory(defines.inventory.chest)
    el.b_line2.caption = string.format("Holds %d items. Part of the logistic network.", inv and inv.get_item_count() or 0)
  elseif rec.kind == "solar" then
    el.b_line2.caption = "Adds 400 kW to the Command Center's power while connected by poles."
  else
    el.b_line2.caption = ""
  end
end

local function update_building(player, h, un, rec)
  local el = h.el
  local e = rec.entity
  if h.bld_un ~= un then rebuild_recipe_buttons(player, h, un, rec) end
  el.b_name.caption = string.format("%s #%d", BUILDING_NAMES[rec.kind] or rec.kind, un)
  local hp, max = e.health or 0, e.max_health or 0
  el.b_hp.caption = max > 0 and string.format("HP %d/%d", math.floor(hp + 0.5), math.floor(max + 0.5)) or ""
  local ratio = max > 0 and hp / max or 1
  el.b_hp.style.font_color = ratio >= 0.66 and COLOR.green or (ratio >= 0.33 and COLOR.yellow or COLOR.red)
  if rec.kind == "barracks" or rec.kind == "factory" then
    update_producer(player, h, un, rec)
  elseif rec.kind == "cc" then
    update_cc(player, h, un, rec)
  else
    update_other(player, h, un, rec)
  end
end

local function update_selection(player, h)
  local un, rec = selected_building(player)
  local el = h.el
  if rec then
    el.unit_page.visible = false
    el.bld_page.visible = true
    update_building(player, h, un, rec)
    return 0
  end
  el.unit_page.visible = true
  el.bld_page.visible = false
  if h.bld_un then
    el.b_buttons.clear()
    h.recipe_buttons, h.bld_un = {}, nil
  end
  return update_units(player, h)
end

---------------------------------------------------------------------------
-- Refresh: strip, build menu
---------------------------------------------------------------------------

--- Notice wave launches and the end of the match (storage.match has no tick for a wave launch).
local function track_match()
  local m, hs = storage.match, storage.hud
  if not (m and hs) then return end
  local wave = m.wave or 0
  if wave ~= hs.wave_seen then
    if wave > (hs.wave_seen or 0) then hs.wave_tick = game.tick end
    hs.wave_seen = wave
  end
  if m.phase == "ended" then
    hs.ended_tick = hs.ended_tick or m.ended_tick or game.tick
  else
    hs.ended_tick = nil
  end
end

-- The match result from the player's view: match.result (Phase 2) when it exists, else from storage.match.winner.
local function result_for(m, own)
  if m.phase ~= "ended" then return nil end
  if match.result then return match.result(own) end
  if m.winner == own then return "victory" end
  if m.winner == "draw" then return "draw" end
  return "defeat"
end

local function match_message(m, own)
  if not (m and m.phase) or m.phase == "setup" then return "Preparing the arena...", COLOR.yellow end
  local result = result_for(m, own)
  if result == "victory" then return "Victory! The enemy base and army are destroyed.", COLOR.green end
  if result == "draw" then return "Draw: both sides are destroyed.", COLOR.yellow end
  if result == "defeat" then return "Defeat. Your base and army are destroyed.", COLOR.red end
  local hs = storage.hud
  if (m.wave or 0) > 0 and hs and hs.wave_tick and game.tick - hs.wave_tick < WAVE_ALERT_TICKS then
    return string.format("Enemy wave %d is attacking!", m.wave), COLOR.red
  end
  if m.enemy_next_wave then
    return string.format("Enemy wave %d in %s", (m.wave or 0) + 1, clock((m.enemy_next_wave - game.tick) / 60)),
      COLOR.yellow
  end
  if m.waves_off then return "Enemy waves off (QA reset). /rts-qa-reset turns them back on.", COLOR.yellow end
  return "Destroy the enemy base and army.", COLOR.yellow
end

-- Player-specific prompts take the message line over the match messages.
local function player_message(player)
  local is_armed = optional_fn("scripts.orders", {"is_armed"})
  if is_armed and is_armed(player.index) then
    return "Attack-move armed: right-click where to go. F or X cancels.", COLOR.red
  end
  local ghost = cursor.ghost_name(player)
  if ghost and prototypes.item[ghost] then
    return {"", "Placing ", prototypes.item[ghost].localised_name,
            ": left-click the map. R rotates. Q or right-click: done."}, COLOR.green
  end
  return nil
end

local function update_strip(player, h)
  local el = h.el
  local m = storage.match
  local hs = storage.hud or {}
  if m and m.tick_started then
    local now = (m.phase == "ended" and hs.ended_tick) or game.tick
    el.timer.caption = clock((now - m.tick_started) / 60)
  else
    el.timer.caption = "--:--"
  end
  local own = player.force.name
  local enemy = own == ENEMY and PLAYER or ENEMY
  el.own.caption = string.format("Army %d", count_force(own))
  el.enemy.caption = string.format("%d Enemy", count_force(enemy))

  local snap = snapshot(own)
  local res = h.res
  if snap then
    for _, r in ipairs(RESOURCES) do res[r.key].caption = fmt_count(snap[r.key]) end
    res.power.caption = string.format("%.1f/%.1f MW", snap.power_demand / 1e6, snap.power_capacity / 1e6)
    local sat = math.floor(snap.power_satisfaction * 100 + 0.5)
    res.power_sat.caption = string.format("%d%%", sat)
    res.power_sat.style.font_color = sat >= 90 and COLOR.green or (sat >= 50 and COLOR.yellow or COLOR.red)
    res.power.style.font_color = snap.power_demand > 0.9 * snap.power_capacity and COLOR.yellow or COLOR.white
    res.bots.caption = string.format("%d/%d", snap.bots_idle, snap.bots_total)
    -- QA log line, when a value changed and at most every RESOURCE_LOG_TICKS:
    -- "hud resources player=N iron=.. copper=.. steel=.. stone=.. magazines=.. power=../.. MW sat=..% bots=../.."
    local line = string.format("iron=%d copper=%d steel=%d stone=%d magazines=%d power=%.2f/%.2f MW sat=%d%% bots=%d/%d",
      snap.iron, snap.copper, snap.steel, snap.stone, snap.magazines, snap.power_demand / 1e6,
      snap.power_capacity / 1e6, sat, snap.bots_idle, snap.bots_total)
    local p = util.pstorage(player.index)
    local last = p.hud_resource_log
    if not last or (last.line ~= line and game.tick - last.tick >= RESOURCE_LOG_TICKS) then
      p.hud_resource_log = {line = line, tick = game.tick}
      util.log("hud resources player=%d %s", player.index, line)
    end
  end

  local text, color = player_message(player)
  if not text then text, color = match_message(m, own) end
  el.message.caption = text
  el.message.style.font_color = color
end

local function update_build_menu(player, h)
  h.build.visible = not prefs(player.index).build_hidden
  if not h.build.visible then return end
  local snap = snapshot(player.force.name)
  local ghost = cursor.ghost_name(player)
  for item, button in pairs(h.build_buttons or {}) do
    if button.valid then
      local n = snap and snap.items[item] or 0
      button.number = n > 0 and n or nil
      button.toggled = ghost == item
      button.enabled = n > 0 or recipe_for(item) ~= nil or ghost == item
      button.tooltip = build_tooltip(item, n)
    end
  end
end

local function update(player, h)
  track_match()
  update_selection(player, h)
  update_commands(player, h)
  update_groups(player, h)
  update_strip(player, h)
  update_build_menu(player, h)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Destroy the player's HUD frames.
function hud.destroy(player)
  local screen = player.gui.screen
  for _, key in pairs({"panel", "strip", "minimap_frame", "minimap", "build"}) do
    local frame = screen[NAMES[key]]
    if frame then frame.destroy() end
  end
  local p = pstate(player.index)
  if p then p.hud = nil end
end

--- (Re)build the player's HUD from scratch. Idempotent.
function hud.build(player)
  hud.destroy(player)
  local screen = player.gui.screen
  local h = {el = {}, groups = {}, res = {}, build_buttons = {}, recipe_buttons = {}}
  build_panel(screen, h)
  build_strip(screen, h)
  build_build_menu(screen, h)
  build_minimap(screen, h)
  util.pstorage(player.index).hud = h
  place(player, h)
  update(player, h)
  local res = player.display_resolution
  util.log("hud: built for player %d (display %dx%d, scale %.2f, density %.2f; minimap zoom %.4f, "
    .. "%.2f px/tile at scale 1; build menu %d items)", player.index, res.width, res.height, player.display_scale,
    player.display_density_scale, MINIMAP_ZOOM, MINIMAP_ZOOM * MINIMAP_PX_PER_TILE_AT_ZOOM_1,
    table_size(h.build_buttons))
  return h
end

--- Update the player's HUD now (selection.lua calls this after every selection change). Builds the HUD
--- when it is missing. Cheap: one pass over the selection and the unit registry, one cached economy snapshot.
function hud.refresh(player_index)
  local player = game.get_player(player_index)
  if not (player and player.connected) then return end
  local h = get_hud(player)
  if not h then
    hud.build(player)
    return
  end
  update(player, h)
end

function hud.init()
  storage.hud = storage.hud or {wave_seen = storage.match and storage.match.wave or 0}
  -- Every module is loaded by now: confirm the package.loaded lookups the buttons depend on.
  local found = {}
  for _, c in ipairs(COMMANDS) do
    found[#found + 1] = string.format("%s=%s", c.action, optional_fn(c.module, c.fns) and "ok" or "MISSING")
  end
  found[#found + 1] = "is_armed=" .. (optional_fn("scripts.orders", {"is_armed"}) and "ok" or "MISSING")
  found[#found + 1] = "group_recall=" .. (optional_fn("scripts.selection", {"group_recall"}) and "ok" or "MISSING")
  found[#found + 1] = "run_command=" .. (optional_fn("scripts.debug", {"run_command"}) and "ok" or "MISSING")
  util.log("hud: module lookup %s", table.concat(found, " "))
  local items = {}
  for _, item in ipairs(build_items()) do
    local r = recipe_for(item)
    items[#items + 1] = string.format("%s<-%s", item, r and r.name or "none")
  end
  util.log("hud: build menu items %s", table.concat(items, " "))
  for _, player in pairs(game.players) do hud.build(player) end
end

---------------------------------------------------------------------------
-- Clicks
---------------------------------------------------------------------------
local function minimap_click(player, h, e, source)
  local world, dx, dy = minimap_to_world(player, h, e.cursor_display_location)
  local loc = h.minimap.location
  util.log("hud click minimap player=%d source=%s button=%s display=(%d, %d) minimap at (%d, %d) "
    .. "offset from centre=(%.1f, %.1f) px -> world %s", player.index, source,
    util.define_name(defines.mouse_button_type, e.button), e.cursor_display_location.x,
    e.cursor_display_location.y, loc.x, loc.y, dx, dy, util.pos_str(world))
  camera.jump_to(player, world)
  return world
end

local function run_command(player, action)
  local c = COMMAND_BY_ACTION[action]
  local fn = optional_fn(c.module, c.fns)
  if not fn then
    local wanted = c.module .. "." .. table.concat(c.fns, "/")
    player.print(string.format("[RTS] %s is not available yet (%s is missing).", c.caption, wanted))
    util.log("hud: button %s: %s missing", action, wanted)
    return
  end
  local result = fn(player.index)
  -- QA log line, one per button: "hud click attack-move|stop|hold|select-all player=N result=..."
  util.log("hud click %s player=%d result=%s", string.gsub(action, "_", "-"), player.index, tostring(result))
end

local function recall_group(player, n)
  local fn = optional_fn("scripts.selection", {"group_recall", "recall_group"})
  if not fn then
    player.print(string.format("[RTS] Control group %d: press %d to recall it.", n, n))
    return
  end
  local selected = fn(player.index, n)
  util.log("hud click group %d player=%d selected=%s", n, player.index, tostring(selected))
end

--- Build menu button: put a ghost of `item` in the cursor (build mode), or end build mode when that item's
--- ghost is already there. QA log line: "hud click build <item> player=N in_network=N ghost=true|false".
function hud.build_click(player, item)
  local snap = snapshot(player.force.name)
  local n = snap and snap.items[item] or 0
  if cursor.ghost_name(player) == item then
    local ok = cursor.ensure(player, true, "build button pressed again")
    util.log("hud click build %s player=%d in_network=%d -> build mode off (tool=%s)", item, player.index, n,
      tostring(ok))
    return false
  end
  local ok = cursor.give_ghost(player, item)
  util.log("hud click build %s player=%d in_network=%d ghost=%s", item, player.index, n, tostring(ok))
  return ok
end

--- Recipe button of the building panel: set (recipe name) or clear ("" = pause) the selected barracks' or
--- factory's recipe through production.set_recipe, which reads it back (a wrong-category recipe stays unset).
--- QA log line: "recipe set <kind>#<unit> <recipe|none> ok=true|false now=<recipe|none> player=N".
function hud.recipe_click(player, recipe)
  local un, rec = selected_building(player)
  if not rec then return false end
  local name = (recipe ~= nil and recipe ~= "") and recipe or nil
  local ok = production.set_recipe(un, name)
  local now = rec.entity.valid and rec.entity.get_recipe()
  util.log("recipe set %s#%d %s ok=%s now=%s player=%d", rec.kind, un, name or "none", tostring(ok),
    now and now.name or "none", player.index)
  return ok
end

local function on_click(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local action = element.tags.rts_hud
  local player = game.get_player(e.player_index)
  local h = get_hud(player)
  if not (action and h) then return end
  if action == "minimap" then
    minimap_click(player, h, e, "mouse")
    return
  elseif action == "group" then
    recall_group(player, element.tags.group)
  elseif action == "build" then
    hud.build_click(player, element.tags.item)
  elseif action == "recipe" then
    hud.recipe_click(player, element.tags.recipe)
  elseif COMMAND_BY_ACTION[action] then
    run_command(player, action)
  end
  hud.refresh(player.index)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
events.on(defines.events.on_gui_click, on_click)

-- Registered after camera.lua's handlers (control.lua requires hud after camera), so the camera is set up first.
events.on(defines.events.on_player_created, function(e)
  hud.build(game.get_player(e.player_index))
end)

events.on(defines.events.on_player_joined_game, function(e)
  hud.build(game.get_player(e.player_index))
end)

-- display_resolution and display_scale are placeholders (1920x1080, 1) during on_player_created; these
-- events follow shortly after with the real values.
local function reposition(e)
  local player = game.get_player(e.player_index)
  local h = player and get_hud(player)
  if not h then return end
  place(player, h)
  local res = player.display_resolution
  util.log("hud: repositioned for player %d (display %dx%d, scale %.2f)", player.index, res.width, res.height,
    player.display_scale)
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

events.on_nth_tick(REFRESH_PERIOD, function()
  for _, player in pairs(game.connected_players) do hud.refresh(player.index) end
end)

-- Production progress of a selected barracks / factory moves faster than the full refresh.
events.on_nth_tick(BUILDING_REFRESH_PERIOD, function(e)
  if e.tick % REFRESH_PERIOD == 0 then return end -- the full refresh runs on this tick
  for _, player in pairs(game.connected_players) do
    local p = pstate(player.index)
    if p and p.building then
      local h = get_hud(player)
      if h then update_selection(player, h) end
    end
  end
end)

-- Build mode starts and ends with cursor changes: the build button's pressed state and the message line follow.
events.on(defines.events.on_player_cursor_stack_changed, function(e) hud.refresh(e.player_index) end)

events.on("rts-build-menu", function(e)
  local pr = prefs(e.player_index)
  pr.build_hidden = not pr.build_hidden
  util.log("hud build menu %s player=%d (B)", pr.build_hidden and "hidden" or "shown", e.player_index)
  hud.refresh(e.player_index)
end)

-- Console-free QA controls (docs/qa/phase1-followups.md item 3): the same code as the console commands,
-- run as the pressing player (debug.run_command checks admin rights like the console does).
local function qa_hotkey(e, command, parameter)
  local fn = optional_fn("scripts.debug", {"run_command"})
  util.log("qa hotkey /%s%s player=%d%s", command, parameter ~= "" and (" " .. parameter) or "", e.player_index,
    fn and "" or " (debug.run_command missing)")
  if fn then fn(command, parameter, e.player_index) end
  hud.refresh(e.player_index)
end
events.on("rts-qa-reset", function(e) qa_hotkey(e, "rts-qa-reset", "nowaves") end)
events.on("rts-qa-end", function(e) qa_hotkey(e, "rts-qa-end", "") end)

-- QA log lines for the build flow: the player placed a ghost, a robot built something.
events.on(defines.events.on_built_entity, function(e)
  local entity = e.entity
  if entity and entity.valid and entity.type == "entity-ghost" then
    util.log("build ghost %s player=%d at %s direction=%s", entity.ghost_name, e.player_index,
      util.pos_str(entity.position), util.define_name(defines.direction, entity.direction))
  end
end)

-- " pickup=(x, y) drop=(x, y)" for inserters, " drop=(x, y)" for extractors: where items go, for QA.
local function io_positions(entity)
  if entity.type == "inserter" then
    return string.format(" pickup=%s drop=%s", util.pos_str(entity.pickup_position), util.pos_str(entity.drop_position))
  elseif entity.type == "mining-drill" then
    return " drop=" .. util.pos_str(entity.drop_position)
  end
  return ""
end

events.on(defines.events.on_robot_built_entity, function(e)
  local entity = e.entity
  if entity and entity.valid then
    util.log("robot built %s #%s at %s direction=%s force=%s%s", entity.name, tostring(entity.unit_number),
      util.pos_str(entity.position), util.define_name(defines.direction, entity.direction), entity.force.name,
      io_positions(entity))
  end
end)

-- R over a built entity (or a ghost) rotates it; QA checks inserter and extractor orientation with this line.
events.on(defines.events.on_player_rotated_entity, function(e)
  local entity = e.entity
  if entity and entity.valid then
    local name = entity.type == "entity-ghost" and (entity.ghost_name .. " (ghost)") or entity.name
    util.log("rotated %s #%s at %s direction=%s player=%d%s", name, tostring(entity.unit_number),
      util.pos_str(entity.position), util.define_name(defines.direction, entity.direction), e.player_index,
      entity.type ~= "entity-ghost" and io_positions(entity) or "")
  end
end)

---------------------------------------------------------------------------
-- Dev-only checks (self-test steps and HUD_CALIBRATE, see the top of this file)
---------------------------------------------------------------------------
local function screenshot(player)
  local path = string.format("rts-hud-%d.png", game.tick)
  local res = player.display_resolution
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {res.width, res.height}, position = player.position, zoom = player.zoom})
  local h = get_hud(player)
  local cx, cy, ppt = 0, 0, 0
  if h then cx, cy, ppt = minimap_geometry(player, h) end
  util.log("hud: screenshot %s at %s zoom %.3f; minimap centre at display (%.1f, %.1f), %.3f px/tile; "
    .. "own CC -> %s, enemy CC -> %s", path, util.pos_str(player.position), player.zoom, cx, cy, ppt,
    h and util.pos_str(world_to_minimap(player, h, match.home(PLAYER))) or "-",
    h and util.pos_str(world_to_minimap(player, h, match.home(ENEMY))) or "-")
end

local CALIBRATION_TAGS = {{x = -64, y = -64, text = "A"}, {x = 64, y = -64, text = "B"},
                          {x = -64, y = 64, text = "C"}, {x = 0, y = 0, text = "O"}}

local function add_calibration_tags()
  local force, surface = game.forces[PLAYER], util.surface()
  for _, t in pairs(CALIBRATION_TAGS) do
    local tag = force.add_chart_tag(surface, {position = {t.x, t.y}, text = t.text,
                                              icon = {type = "virtual", name = "signal-" .. t.text}})
    util.log("hud: calibration tag %s at %s: %s", t.text, util.pos_str(t), tostring(tag ~= nil))
  end
end

local function synthetic_click(player)
  local h = get_hud(player)
  if not h then return end
  local target = {x = 50, y = 0}
  local display = world_to_minimap(player, h, target)
  local world = minimap_click(player, h, {player_index = player.index, button = defines.mouse_button_type.left,
                                           cursor_display_location = display}, "synthetic")
  util.log("hud: synthetic click aimed at %s, round trip error %.2f tiles", util.pos_str(target),
    util.distance(world, target))
end

local function zero_area(pos)
  return {left_top = {x = pos.x, y = pos.y}, right_bottom = {x = pos.x, y = pos.y}}
end

local function cursor_summary(player)
  return string.format("tool=%s ghost=%s", tostring(cursor.holds_tool(player)), cursor.ghost_name(player) or "none")
end

-- Self-test barracks spot: next to the CC, clear of the stockpiles and the starting army.
local SELFTEST_BARRACKS_OFFSET = {x = 5.5, y = -8.5}
local SELFTEST_FACTORY_OFFSET = {x = 5.5, y = 8.5}
local SELFTEST_RALLY_OFFSET = {x = 16, y = -10}

local function own_barracks(player)
  for un, rec in buildings.for_force(player.force.name, "barracks") do return un, rec end
  return nil
end

-- Self-test steps: camera.lua runs them `at` ticks after the player's setup, only while the self-test
-- switch is on (camera.selftest_enabled()). Registered at load time, identically on every load.
if HUD_CALIBRATE then
  camera.add_selftest_step(180, "hud_calibrate", function() add_calibration_tags() end)
end
camera.add_selftest_step(390, "hud_build_click", function(player)
  hud.build_click(player, "rts-barracks")
  util.log("hud: selftest build click: %s", cursor_summary(player))
end)
camera.add_selftest_step(420, "hud_screenshot_build_mode", screenshot) -- message line + pressed build button
camera.add_selftest_step(450, "hud_build_place", function(player)
  local home = match.home(player.force.name)
  local pos = {x = home.x + SELFTEST_BARRACKS_OFFSET.x, y = home.y + SELFTEST_BARRACKS_OFFSET.y}
  local ok, err = pcall(player.build_from_cursor, {position = pos})
  local ghosts = player.surface.count_entities_filtered({position = pos, radius = 1, type = "entity-ghost"})
  if ghosts == 0 then
    -- build_from_cursor did not place it (not supported for a ghost cursor): place the ghost by script instead
    player.surface.create_entity({name = "entity-ghost", inner_name = "rts-barracks", position = pos,
                                  force = player.force, raise_built = true})
    ghosts = player.surface.count_entities_filtered({position = pos, radius = 1, type = "entity-ghost"})
  end
  util.log("hud: selftest build_from_cursor at %s ok=%s%s; ghosts there=%d; %s", util.pos_str(pos), tostring(ok),
    ok and "" or (" err=" .. tostring(err)), ghosts, cursor_summary(player))
  local fpos = {x = home.x + SELFTEST_FACTORY_OFFSET.x, y = home.y + SELFTEST_FACTORY_OFFSET.y}
  player.surface.create_entity({name = "entity-ghost", inner_name = "rts-factory", position = fpos,
                                force = player.force, raise_built = true})
end)
camera.add_selftest_step(480, "hud_cursor_clear", function(player)
  player.clear_cursor() -- what Q does
  util.log("hud: selftest clear_cursor: %s", cursor_summary(player))
end)
camera.add_selftest_step(510, "hud_cursor_check", function(player)
  util.log("hud: selftest cursor 30 ticks after clear: %s", cursor_summary(player))
end)
-- Armed attack-move through the button path; a screenshot shows the red button and the strip prompt (debug.lua's
-- step 270 disarms in the same tick as its screenshot, and screenshots are rendered at the end of the tick).
-- camera.lua runs every due step in one 30-tick sweep, so steps that must be seen apart are 30 ticks apart.
camera.add_selftest_step(510, "hud_arm_attack_move", function(player) run_command(player, "attack_move") end)
camera.add_selftest_step(540, "hud_screenshot_armed", screenshot)
camera.add_selftest_step(570, "hud_disarm_attack_move", function(player) run_command(player, "attack_move") end)
camera.add_selftest_step(540, "hud_select_all_group1", function(player)
  run_command(player, "select_all")
  local group_set = optional_fn("scripts.selection", {"group_set"}) -- group 1 indicator: "1: 24", toggled
  if group_set then group_set(player.index, 1) end
  hud.refresh(player.index)
end)
camera.add_selftest_step(600, "hud_screenshot_600", screenshot)
camera.add_selftest_step(660, "hud_minimap_click", synthetic_click)
camera.add_selftest_step(720, "hud_screenshot_720", screenshot)
camera.add_selftest_step(780, "hud_home", function(player) camera.home(player) end)
camera.add_selftest_step(820, "hud_select_cc", function(player)
  local handle_area = optional_fn("scripts.selection", {"handle_area"})
  local cc = buildings.main_cc(player.force.name)
  if handle_area and cc then handle_area(player.index, {}, zero_area(cc.entity.position), false, player.surface) end
  hud.refresh(player.index)
  local un = selected_building(player)
  util.log("hud: selftest click on the CC at %s -> selected building #%s", cc and util.pos_str(cc.entity.position) or "-",
    tostring(un))
end)
camera.add_selftest_step(840, "hud_screenshot_840", screenshot)
camera.add_selftest_step(860, "hud_select_barracks", function(player)
  local handle_area = optional_fn("scripts.selection", {"handle_area"})
  local reverse = optional_fn("scripts.orders", {"handle_reverse_area"})
  local un, rec = own_barracks(player)
  if not (rec and handle_area) then
    util.log("hud: selftest no own barracks yet (robots have not built the ghost)")
    return
  end
  handle_area(player.index, {}, zero_area(rec.entity.position), false, player.surface)
  hud.recipe_click(player, "rts-walker-kit")
  local home = match.home(player.force.name)
  local rally = {x = home.x + SELFTEST_RALLY_OFFSET.x, y = home.y + SELFTEST_RALLY_OFFSET.y}
  local order, n = "none", 0
  if reverse then order, n = reverse(player.index, {}, zero_area(rally), false) end
  hud.refresh(player.index)
  util.log("hud: selftest barracks #%d selected=%s, right click at %s -> %s %s", un,
    tostring(selected_building(player) == un), util.pos_str(rally), tostring(order), tostring(n))
end)
-- Same sweep as RTS_GUI_READY (960, after debug.lua's qa_reset at 930 cleared the selection): selecting and
-- screenshotting in one step is fine, because the screenshot is rendered at the end of the tick.
camera.add_selftest_step(960, "hud_factory", function(player)
  local handle_area = optional_fn("scripts.selection", {"handle_area"})
  for un, rec in buildings.for_force(player.force.name, "factory") do
    if handle_area then handle_area(player.index, {}, zero_area(rec.entity.position), false, player.surface) end
    hud.recipe_click(player, "rts-extractor")
    hud.refresh(player.index)
    util.log("hud: selftest factory #%d selected=%s", un, tostring(selected_building(player) == un))
    screenshot(player)
    return
  end
  util.log("hud: selftest no own factory (robots have not built the ghost)")
end)
camera.add_selftest_step(3000, "hud_done", function(player) -- about 5 s into the first enemy wave
  screenshot(player)
  util.log("RTS_HUD_DONE player %d", player.index)
end)

return hud
