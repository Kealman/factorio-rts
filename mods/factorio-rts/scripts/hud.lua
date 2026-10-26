-- HUD: four areas in player.gui.screen.
--   bottom-left   selection panel. With units selected: count, average health, current order, kinds,
--                 control-group indicators 1-5, four command buttons. With an own building selected (Phase 2):
--                 its name and health, then per kind: barracks / factory recipe grid (Pause first, 6 per row),
--                 production progress, counters and the rally point; Command Center bots and power; turret ammo;
--                 others their status. The panel is wide and low, so it stays below the console (chat).
--   bottom-right  build menu (Phase 2): one slot button per placeable item with the count in the logistic network;
--                 a click puts a ghost of the item in the cursor (cursor.give_ghost). B shows / hides it.
--   top-centre    match strip: timer and own vs enemy unit counts; the resource row (iron, copper, steel, stone,
--                 magazines, power, bots from economy.snapshot); a message line (attack-move armed, build mode,
--                 enemy waves, match result)
--   top-right     minimap of the arena (directly on `screen`, over a decorative frame); a click jumps the
--                 camera there (camera.jump_to). The vanilla entity tooltip, which the game draws in that corner,
--                 is switched off (HIDE_ENTITY_TOOLTIP).
-- Phase 4 (docs/PHASE4.md section 7, docs/qa/phase2-hud-notes.md "Phase 4"):
--   selection panel  unit cards (one per unit prototype: icon, count, HP bar; a click keeps only that kind, Shift +
--                    click drops it); barracks / factory grids grey out recipes the force cannot use yet (disabled
--                    recipe or a unit locked by research) with "Requires research: X"; the barracks page shows
--                    research.block_of (kit waiting for research or for supply); pages for the Phase 4 buildings.
--   build menu       three tabs (Economy, Production, Defence and power), locked items greyed out.
--   strip            supply used/cap (supply.get), circuits and explosives, Research [T] and How to play [F11]
--                    buttons. Below it the alert lines: the newest 3 storage.alerts of the player's force, 15 s,
--                    fading; a click or F3 (rts-alert-jump, repeated presses cycle) jumps the camera there; a minimap
--                    ping (chart tag) for 10 s. This module writes "base-attacked" (own building damaged by another
--                    force, at most every 20 s per force).
--   top-left         kill feed: the last 5 unit deaths the player's force saw ("Walker ✕ (AI 1)"), fading.
--   centre           "How to play" (F11 / the ? button): 10 lines, en and ru.
--
-- Every player-facing text is a localised string from the [rts] section of locale/*/factorio-rts.cfg
-- ({"rts.key", parameters...}); prototype names come from the prototypes (localised_name). Only numbers,
-- key names (F, Ctrl+A), positions and rich-text icons are built here. See docs/qa/phase2-polish-notes.md.
--
-- Owns storage.players[i].hud = {panel, strip, minimap_frame, minimap, build, alerts, kills (LuaGuiElement),
--   el = {...}, groups = {...}, res = {...}, build_buttons = {[item] = button}, recipe_buttons = {[recipe or ""] =
--   button}, recipe_locks = {[recipe] = tech | true | false}, bld_un = unit number the recipe buttons were built for,
--   cards = {[unit name] = {button, bar}}, card_key = names the cards were built for, alert_lines, kill_lines},
-- storage.players[i].hud_prefs = {build_hidden, build_tab} (survives HUD rebuilds), storage.players[i].hud_resource_log
-- = {line, tick} (last "hud resources" QA line), .hud_alert = {seen_tick, jump_tick, jump_index} (alert sound and
-- F3 cycling)
-- and storage.hud = {wave_seen, wave_tick, ended_tick (match-event tracking shared by all players),
--   attack_alert = {[force] = tick} (base-attacked rate limit), kills = {{tick, name, force, killer, killer_force,
--   seen = {[force] = true}}, ...} (kill feed, newest last), pings = {{tag, tick}, ...}, ping_tick}.
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
-- Phase 4: control.lua loads these before the HUD, so requiring them here registers nothing new.
local supply = require("scripts.supply")
local research = require("scripts.research")
local logistics = require("scripts.logistics")
local demolish = require("scripts.demolish")
local pieces = require("scripts.pieces")
local balance = require("balance")

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
--   960   click-selects the factory (placed as a ghost at 450), extractor recipe, screenshot (12 recipe buttons)
--   3000  screenshot, then the "RTS_HUD_DONE" marker
-- HUD_CALIBRATE (a load-time constant): at setup + 180 adds chart tags A, B, C at (-64,-64), (64,-64),
-- (-64,64) and O at (0,0), to measure the minimap scale from a screenshot (docs/qa/phase1-hud-notes.md).
local HUD_CALIBRATE = false

-- The vanilla entity tooltip (the info box shown while hovering an entity) is drawn in the top-right corner,
-- half under the HUD minimap (docs/qa/phase2-qa-results.md steps 3 and 10). The HUD owns that corner, so it
-- switches the tooltip off. Hovering itself (player.selected, building clicks) is update_entity_selection,
-- which camera.lua keeps on. false = leave the vanilla tooltip alone.
local HIDE_ENTITY_TOOLTIP = true

local REFRESH_PERIOD = 30          -- ticks; full refresh (counts, resources, dead units, timer)
local BUILDING_REFRESH_PERIOD = 10 -- ticks; building panel only (production progress), while one is selected
local WAVE_ALERT_TICKS = 10 * 60   -- how long "wave N is attacking" stays on the message line
local RESOURCE_LOG_TICKS = 5 * 60  -- the "hud resources" QA line is written at most this often (on change)

-- Layout, in GUI units (multiplied by player.display_scale on screen).
-- The selection panel is wide and low: the console (chat) has no GameViewSettings switch and its last line ends
-- about 135 GUI units above the bottom of the screen, so the panel's top (PANEL_HEIGHT + MARGIN) stays below it.
-- Phase 4: 126 high (unit cards with HP bars, the factory's 2 x 14 recipe grid); its top, 134 units above the bottom,
-- is still below the console. 520 wide: the ability bar (scripts/abilitygui.lua) centres between this panel and the
-- build menu. Its HUD_LEFT / HUD_RIGHT copy MARGIN, PANEL_WIDTH and BUILD_WIDTH: change them together.
local MARGIN = 8
local FRAME_PADDING_X = 16         -- rts_hud_frame: 8 left + 8 right
local PANEL_WIDTH, PANEL_HEIGHT = 520, 126
local PANEL_INNER = PANEL_WIDTH - FRAME_PADDING_X
local STRIP_WIDTH, STRIP_HEIGHT = 720, 96 -- Phase 4: 720 (was 600) for supply, circuits, explosives and two buttons
local STRIP_INNER = STRIP_WIDTH - FRAME_PADDING_X
-- Phase 4 layout and timing constants live in one table: the main chunk is close to Lua's 200-local limit.
local P4 = {
  -- Unit cards: one 30 px slot button per unit prototype in the selection with its count, an HP bar under it. At most
  -- CARD_MAX in the row left of the control-group buttons; with more prototypes the last slot reads "+N".
  CARD_SIZE = 30, CARD_SPACING = 2, CARD_MAX = 6,
  -- The factory has 25 recipes, so its grid takes the whole panel width (2 rows of 14, 14 x 34 + 13 x 2 = 502 of
  -- 504) and its status moves to a line under the grid.
  FACTORY_COLUMNS = 14, FACTORY_STATUS_WIDTH = 250, FACTORY_PROGRESS_WIDTH = 80, FACTORY_COUNTS_WIDTH = 160,
  -- Alert lines under the strip: the newest ALERT_SHOWN of the player's force, ALERT_TICKS long, fading out over the
  -- last ALERT_FADE_TICKS. base-attacked at most once per force in ATTACK_ALERT_PERIOD. F3 again within
  -- ALERT_JUMP_CYCLE_TICKS: the next older alert. A minimap ping (chart tag) stays PING_TICKS.
  ALERT_WIDTH = 520, ALERT_SHOWN = 3, ALERT_TICKS = 15 * 60, ALERT_FADE_TICKS = 3 * 60,
  ATTACK_ALERT_PERIOD = 20 * 60, ALERT_JUMP_CYCLE_TICKS = 5 * 60, PING_TICKS = 10 * 60,
  -- Kill feed in the top-left corner: the last KILL_SHOWN deaths, KILL_TICKS long, KILL_KEEP kept in storage.
  KILL_WIDTH = 260, KILL_SHOWN = 5, KILL_TICKS = 20 * 60, KILL_FADE_TICKS = 5 * 60, KILL_KEEP = 30,
  FEED_PERIOD = 10, -- ticks; alert lines and kill feed (fading) refresh
  HELP_WIDTH = 640, HELP_LINES = 10, -- "How to play": rts.help-1 .. rts.help-10
  -- Phase 5 M2 integration: the Nation page (goal, controls, people, treasury, diplomacy and war, supply, rails and
  -- ages, every hotkey; P4.KEYS are its panel keys)
  HELP_NATION = {"rts.help-nation-1", "rts.help-2", "rts.help-nation-2", "rts.help-nation-3", "rts.help-nation-4",
                 "rts.help-nation-5", "rts.help-nation-6",
                 "rts-age3.help-nation-age3", -- Phase 5 M3 integration: Age III, Space Program, rare bonuses, sinks
                 "rts-war3.help-nation-fronts", -- Phase 5 M3 war2: fronts, hold line, fort belts, war trains
                 "rts.help-nation-keys"},
  DEMOLISH_HEIGHT = 22, -- the building page's Demolish button (header row)
  -- Phase 5 E1: the factory / district Auto button (recipe tag) and the Nation-only Age II build tab (two rows when it
  -- holds more than BUILD_COLUMNS items; the frame grows upwards by BUILD_ROW per extra row)
  AUTO = "*auto*", ENDLESS = "*endless*", BUILD_ROW = 42, AGE2_TAB_WIDTH = 26, TAB_PADDING_NATION = 5, -- (the text tabs narrow a little)
}
P4.CARDS_WIDTH = P4.CARD_MAX * P4.CARD_SIZE + (P4.CARD_MAX - 1) * P4.CARD_SPACING -- 190
-- Phase 5 M1 (scripts/cities.lua, scripts/territory.lua): build items and factory recipes shown in Nation mode only;
-- the strip shows the territory share and a Cities button (scripts/citygui.lua city list) in Nation mode.
P4.NATION_ONLY = {["rts-city-charter"] = true, ["rts-fort"] = true}
P4.nation = function()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end
for _, name in ipairs({"rts-depot", "rts-rail", "rts-locomotive-kit", "rts-cargo-wagon-kit", "rts-construction-wagon-kit",
                       "rts-district-rails", "rts-dra-rail"}) do -- Phase 5 M2 integration: the Rail works (Railways)
  P4.NATION_ONLY[name] = true end -- Phase 5 M1 (m1-rails): the depot item, the rail and kit recipes
for _, name in ipairs({"rts-house", "rts-apartment", "rts-farm", "rts-bakery", "rts-fishing-hut", "rts-goods",
                       "rts-brick"}) do
  P4.NATION_ONLY[name] = true end -- Phase 5 M2 people: houses, the food chain, goods and factory bricks
-- Phase 5 M2 war: supply crates (both recipes), the field depot, the troop wagon kit
for _, name in ipairs({"rts-supply-crate", "rts-supply-crate-ii", "rts-field-depot", "rts-troop-wagon-kit"}) do
  P4.NATION_ONLY[name] = true end
-- Phase 5 M3 air: the airfield, the AA turret and the plane kits (Aviation, Air Force); the Nation help page's air line
for _, name in ipairs({"rts-airfield", "rts-aa-turret", "rts-scout-plane-kit", "rts-bomber-kit", "rts-interceptor-kit"}) do
  P4.NATION_ONLY[name] = true end
table.insert(P4.HELP_NATION, #P4.HELP_NATION, "rts-ux.help-nation-oil") -- #28
table.insert(P4.HELP_NATION, #P4.HELP_NATION, "rts-air.help-nation-air") -- Phase 5 M3 integration: before the keys
-- Phase 5 M3 war2: the gate, the artillery wagon, armoured stock and rail shells
for _, name in ipairs({"rts-gate", "rts-artillery-wagon-kit", "rts-armoured-locomotive-kit", "rts-armoured-wagon-kit",
                       "rts-rail-shell"}) do
  P4.NATION_ONLY[name] = true end
-- Release 0.1.2 (#25): the long-handed inserter (recipe and build item) is Nation only: the Skirmish factory page holds
-- 28 buttons (two rows of 14, Pause included) and the underground belt and splitter already fill it.
for _, name in ipairs({"rts-long-inserter", "long-handed-inserter"}) do P4.NATION_ONLY[name] = true end
P4.crafter = function(kind) return kind == "factory" or kind == "district" end -- Phase 5 E1: districts are producers
P4.place_name = require("scripts.world").place_name -- Phase 5 M2 world: region names in alerts (alert_text)
-- Phase 5 E1: recipes an age locks (research.AGE_LOCKS: Age II goods, buildings, the Armoured car kit) exist in Nation
-- mode only, like P4.NATION_ONLY.
P4.visible_recipe = function(name)
  return P4.nation() or not (P4.NATION_ONLY[name] or research.AGE_LOCKS[name])
end
-- Phase 5 E1: the factory's recipe grid holds 28 buttons, Nation mode has more recipes: a tab row in the page header
-- (Nation mode, factories only) shows one category at a time. Skirmish keeps the single grid.
P4.FACTORY_TABS = {
  {key = "buildings", sprite = "item/rts-factory", tooltip = "rts.factory-tab-buildings"},
  {key = "logistics", sprite = "item/transport-belt", tooltip = "rts.factory-tab-logistics"},
  {key = "intermediates", sprite = "item/iron-gear-wheel", tooltip = "rts.factory-tab-intermediates"},
  {key = "science", sprite = "item/rts-science-basic", tooltip = "rts.factory-tab-science"},
  {key = "age2", sprite = "item/rts-science-industrial", tooltip = "rts.factory-tab-age2"},
}
P4.LOGISTICS_PRODUCTS = {["transport-belt"] = true, ["fast-inserter"] = true, ["underground-belt"] = true,
  ["splitter"] = true, ["long-handed-inserter"] = true, ["medium-electric-pole"] = true,
  ["firearm-magazine"] = true, ["rts-hauler-kit"] = true, rail = true, ["rts-locomotive-kit"] = true,
  ["rts-cargo-wagon-kit"] = true, ["rts-construction-wagon-kit"] = true,
  ["rts-supply-crate"] = true, ["rts-troop-wagon-kit"] = true, -- Phase 5 M2 war
  ["rts-artillery-wagon-kit"] = true, ["rts-armoured-locomotive-kit"] = true, ["rts-armoured-wagon-kit"] = true,
  ["rts-rail-shell"] = true} -- Phase 5 M3 war2
P4.recipe_tab = function(r)
  local cat = util.recipe_category(r) -- 2.1: LuaRecipePrototype::category -> categories
  if cat == "rts-science" then return "science" end
  if cat == "rts-intermediates" or cat == "rts-age2" then return "intermediates" end
  local product = r.products and r.products[1]
  if product and P4.LOGISTICS_PRODUCTS[product.name] then return "logistics" end
  if r.subgroup and r.subgroup.name == "rts-districts" then return "age2" end
  return "buildings"
end
-- Recipe grid of a barracks / factory: Pause first, then the recipes (group, subgroup, recipe order), at most
-- RECIPE_COLUMNS per row, so a new recipe never moves Pause and only shifts the recipes after it.
local RECIPE_COLUMNS = 6
local RECIPE_BUTTON, RECIPE_SPACING = 34, 2 -- rts_hud_recipe_button size
local RECIPE_GRID_WIDTH = RECIPE_COLUMNS * RECIPE_BUTTON + (RECIPE_COLUMNS - 1) * RECIPE_SPACING -- 214
local BODY_SPACING = 8             -- between the recipe grid and the text column
local TEXT_WITH_GRID = PANEL_INNER - RECIPE_GRID_WIDTH - BODY_SPACING -- 282
-- Build menu (Phase 4): three tabs, at most 7 slot buttons each.
local BUILD_COLUMNS = 7
local BUILD_WIDTH, BUILD_HEIGHT = 308, 112 -- 7 x 40 + 6 x 2 + 16
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
-- Phase 3: the arena size comes from the match config (256 or 384 tiles); the minimap shows the whole arena.
local function minimap_zoom()
  local half = match.arena_half and match.arena_half() or ARENA_HALF
  return MINIMAP_SIZE / ((2 * half + 16) * MINIMAP_PX_PER_TILE_AT_ZOOM_1)
end

local NAMES = {panel = "rts_hud_panel", strip = "rts_hud_strip", minimap_frame = "rts_hud_minimap_frame",
               minimap = "rts_hud_minimap", build = "rts_hud_build", alerts = "rts_hud_alerts",
               kills = "rts_hud_kills"}
local HELP_FRAME = "rts_hud_help" -- created on demand, not part of the HUD's frame set
local PREFIX = "rts_hud_"          -- every clickable HUD element's name starts with this

-- Locale keys ([rts] section).
local KIND_KEYS = {walker = "rts.kind-walker", heavy = "rts.kind-heavy", drone = "rts.kind-drone",
                   raider = "rts.kind-raider", artillery = "rts.kind-artillery", hauler = "rts.kind-hauler",
                   commander = "rts.kind-commander"}
KIND_KEYS["scout-plane"] = "rts-air.kind-scout-plane" -- Phase 5 M3 air (the counter wheel of card tooltips)
KIND_KEYS["bomber"] = "rts-air.kind-bomber"
KIND_KEYS["interceptor"] = "rts-air.kind-interceptor"
local KIND_RANK = {commander = 0, walker = 1, heavy = 2, drone = 3, raider = 4, artillery = 5, hauler = 6}
local ORDER_KEYS = {idle = "rts.order-idle", move = "rts.order-move", attack = "rts.order-attack",
                    attack_move = "rts.order-attack-move", hold = "rts.order-hold", haul = "rts.order-haul",
                    commander = "rts.order-commander"}
-- Phase 5 M3 air: the planes' own orders (scripts/air.lua)
ORDER_KEYS.patrol = "rts-air.order-patrol"
ORDER_KEYS["return"] = "rts-air.order-return"
ORDER_KEYS.rearm = "rts-air.order-rearm"

-- Phase 4 unit data from balance.lua: kit recipe -> unit for the barracks kits (the hauler kit is the factory's,
-- made_by = "factory"), and the mk2 kits, which research never enables (Armor I deploys mk2 units from tier-1 kits),
-- so the barracks grid leaves them out.
local KIT_UNIT, HIDDEN_KITS = {}, {}
for name, u in pairs(balance.units) do
  if u.kit and not u.made_by then
    if u.base then HIDDEN_KITS[u.kit] = true else KIT_UNIT[u.kit] = name end
  end
end
local FEED_KEYS = {fed = "rts.turret-fed", ["network empty"] = "rts.turret-network-empty",
                   ["no network"] = "rts.turret-no-network"}

local COLOR = {
  white = {1, 1, 1},
  gold = {1, 0.84, 0.6},
  dim = {0.72, 0.72, 0.72},
  yellow = {1, 0.85, 0.3},
  red = {1, 0.42, 0.36},
  green = {0.5, 1, 0.5},
  own = {0.5, 0.72, 1},
  enemy = {1, 0.5, 0.45},
}

-- Command buttons. Each calls the first of module[fns[i]](player_index) that exists at click time; a button with
-- `input` runs every handler of that custom input instead, exactly like its key (Phase 4: the Commander's stop).
-- caption / tooltip are [rts] locale keys; key is the key name shown in brackets (prototypes/inputs.lua).
local COMMANDS = {
  {action = "attack_move", caption = "rts.cmd-attack-move", key = "F", module = "scripts.orders",
   fns = {"arm_attack_move"}, tooltip = "rts.cmd-attack-move-tooltip"},
  {action = "stop", caption = "rts.cmd-stop", key = "X", module = "scripts.orders", fns = {"stop"},
   tooltip = "rts.cmd-stop-tooltip", input = "rts-stop"},
  {action = "hold", caption = "rts.cmd-hold", key = "H", module = "scripts.orders", fns = {"hold"},
   tooltip = "rts.cmd-hold-tooltip", input = "rts-hold"},
  {action = "select_all", caption = "rts.cmd-select-all", key = "Ctrl+A", module = "scripts.selection",
   fns = {"select_all"}, tooltip = "rts.cmd-select-all-tooltip"},
}
local COMMAND_BY_ACTION = {}
for _, c in pairs(COMMANDS) do COMMAND_BY_ACTION[c.action] = c end
local GROUP_COUNT = 5

-- Build menu tabs, in button order (Phase 4). The belt, inserter and pole are the vanilla items
-- (docs/qa/phase2-prototypes-notes.md "Reused vanilla entities"). An item without an rts recipe is disabled while the
-- network holds none of it; an item whose recipe the force has not unlocked is greyed out with the technology in its
-- tooltip (it can still be placed while the network holds some).
local BUILD_TABS = {
  {key = "economy", caption = "rts.build-tab-economy", tooltip = "rts.build-tab-economy-tooltip",
   items = {"rts-extractor", "rts-smelter", "rts-stockpile", "transport-belt", "underground-belt", "splitter",
            "fast-inserter", "long-handed-inserter", "medium-electric-pole",
            "rts-hub", "rts-depot", -- Phase 5 M1: rts-depot is Nation-only (P4.NATION_ONLY)
            "rts-district-rails"}}, -- Phase 5 M2 integration: the Rail works comes with Railways in Age I
  {key = "production", caption = "rts.build-tab-production", tooltip = "rts.build-tab-production-tooltip",
   items = {"rts-barracks", "rts-factory", "rts-lab", "rts-city-charter", "rts-fort", -- Phase 5 M1: Nation only
            "rts-house", "rts-apartment", "rts-farm", "rts-bakery", "rts-fishing-hut", -- Phase 5 M2 people: Nation only
            "rts-field-depot", -- Phase 5 M2 war: Nation only
            "rts-airfield"}}, -- Phase 5 M3 air: Nation only (Aviation)
  {key = "defence", caption = "rts.build-tab-defence", tooltip = "rts.build-tab-defence-tooltip",
   items = {"rts-turret", "rts-laser-turret", "rts-wall", "rts-solar-array", "rts-steam-plant", "rts-accumulator",
            "rts-radar", "rts-aa-turret", -- Phase 5 M3 air: the AA turret, Nation only (Aviation)
            "rts-gate"}}, -- Phase 5 M3 war2: Nation only (Fortification)
  -- Phase 5 E1: Age II buildings, Nation mode only (an icon tab: the three text tabs fill the width in Russian)
  {key = "age2", sprite = "item/rts-science-industrial", tooltip = "rts.build-tab-age2-tooltip", nation = true,
   items = {"rts-pumpjack", "rts-refinery", "rts-chemical-plant", "rts-district-smelting", "rts-district-steel",
            "rts-district-circuits", "rts-district-electronics", "rts-district-petrochem", "rts-district-engines",
            "rts-district-munitions", "rts-district-construction", "rts-district-science",
            "rts-bunker",
            -- Phase 5 M3 age3: Geology's rare extractor, the Age III districts and the nuclear plant (a third row)
            "rts-rare-extractor", "rts-district-chemistry", "rts-district-electronics2", "rts-district-concrete",
            "rts-nuclear-plant"}},
}
local BUILD_TAB_BY_KEY = {}
for _, tab in ipairs(BUILD_TABS) do BUILD_TAB_BY_KEY[tab.key] = tab end
local BUILD_ITEMS = {}
for _, tab in ipairs(BUILD_TABS) do
  for _, item in ipairs(tab.items) do BUILD_ITEMS[#BUILD_ITEMS + 1] = item end
end
local RTS_CATEGORIES = {["rts-buildings"] = true, ["rts-units"] = true}

-- Top-strip resources: economy.snapshot field, icon, tooltip key.
-- `item` (Phase 4): read snapshot.items[item] instead of the snapshot field `key`.
local RESOURCES = {
  {key = "iron", sprite = "item/iron-plate", tooltip = "rts.res-iron-tooltip"},
  {key = "copper", sprite = "item/copper-plate", tooltip = "rts.res-copper-tooltip"},
  {key = "steel", sprite = "item/steel-plate", tooltip = "rts.res-steel-tooltip"},
  {key = "circuits", item = "electronic-circuit", sprite = "item/electronic-circuit",
   tooltip = "rts.res-circuits-tooltip"},
  {key = "explosives", item = "rts-explosives", sprite = "item/rts-explosives", tooltip = "rts.res-explosives-tooltip"},
  {key = "stone", sprite = "item/stone", tooltip = "rts.res-stone-tooltip"},
  {key = "magazines", sprite = "item/firearm-magazine", tooltip = "rts.res-magazines-tooltip"},
}

-- Alert kinds (storage.alerts): icon (first valid sprite path wins), text colour, sound when it arrives.
P4.ALERT_STYLE = {
  ["base-attacked"] = {icons = {"utility/danger_icon", "utility/warning_icon"}, color = "red",
                       sound = "utility/alert_destroyed"},
  ["hauler-lost"] = {icons = {"entity/rts-hauler", "utility/danger_icon"}, color = "red",
                     sound = "utility/alert_destroyed"},
  ["supply-blocked"] = {icons = {"utility/warning_icon"}, color = "yellow"},
  ["unit-locked"] = {icons = {"item/rts-science-basic", "utility/warning_icon"}, color = "yellow"},
  ["research-complete"] = {icons = {"item/rts-science-advanced", "utility/check_mark_green"}, color = "green"},
  ["patch-depleted"] = {icons = {"item/iron-ore", "utility/warning_icon"}, color = "yellow"},
  ["ruin-captured"] = {icons = {"item/steel-plate", "utility/check_mark_green"}, color = "green"},
  ["commander-down"] = {icons = {"entity/rts-commander", "utility/danger_icon"}, color = "red",
                        sound = "utility/alert_destroyed"},
  ["commander-ready"] = {icons = {"entity/rts-commander", "utility/check_mark_green"}, color = "green"},
  -- Phase 5 M1 (m1-rails): rail lines and trains
  ["line-open"] = {icons = {"item/rail", "utility/check_mark_green"}, color = "green"},
  ["hauler-no-fuel"] = {icons = {"item/coal", "utility/warning_icon"}, color = "yellow"},
  ["line-cut"] = {icons = {"item/rail", "utility/danger_icon"}, color = "red", sound = "utility/alert_destroyed"},
  ["line-blocked"] = {icons = {"item/rail", "utility/warning_icon"}, color = "yellow"},
  ["line-failed"] = {icons = {"item/rail", "utility/warning_icon"}, color = "yellow"},
  ["train-lost"] = {icons = {"entity/rts-locomotive", "utility/danger_icon"}, color = "red",
                    sound = "utility/alert_destroyed"},
  -- Phase 5 M1 (scripts/cities.lua)
  ["city-founded"] = {icons = {"item/rts-city-charter", "utility/check_mark_green"}, color = "green"},
  ["city-tier"] = {icons = {"item/rts-city-charter", "utility/check_mark_green"}, color = "green"},
  ["city-lost"] = {icons = {"item/rts-city-charter", "utility/danger_icon"}, color = "red",
                   sound = "utility/alert_destroyed"},
  ["territory-lost"] = {icons = {"utility/warning_icon"}, color = "yellow"},
  -- Phase 5 M2 treasury (scripts/treasury.lua, scripts/market.lua)
  ["treasury-stage"] = {icons = {"entity/rts-trade-post", "utility/danger_icon"}, color = "red",
                        sound = "utility/alert_destroyed"},
  ["treasury-recovered"] = {icons = {"entity/rts-trade-post", "utility/check_mark_green"}, color = "green"},
  ["port-captured"] = {icons = {"entity/rts-trade-post", "utility/check_mark_green"}, color = "green"},
  ["port-lost"] = {icons = {"entity/rts-trade-post", "utility/danger_icon"}, color = "red",
                   sound = "utility/alert_destroyed"},
  ["import-arrived"] = {icons = {"entity/rts-trade-post", "utility/check_mark_green"}, color = "green"},
  ["import-lost"] = {icons = {"entity/rts-trade-post", "utility/warning_icon"}, color = "yellow"},
  -- Phase 5 M2 diplomacy (scripts/diplomacy.lua, scripts/wars.lua); proposals also show Accept / Decline under the lines
  ["diplomacy-war"] = {icons = {"utility/danger_icon"}, color = "red", sound = "utility/alert_destroyed"},
  ["diplomacy-ceasefire"] = {icons = {"utility/warning_icon"}, color = "yellow"},
  ["diplomacy-peace"] = {icons = {"utility/check_mark_green"}, color = "green"},
  ["diplomacy-alliance"] = {icons = {"utility/check_mark_green"}, color = "green"},
  ["diplomacy-proposal"] = {icons = {"utility/warning_icon"}, color = "yellow", sound = "utility/new_objective"},
  ["diplomacy-answer"] = {icons = {"utility/check_mark_green"}, color = "green"},
  ["diplomacy-declined"] = {icons = {"utility/warning_icon"}, color = "yellow"},
  ["diplomacy-news"] = {icons = {"utility/warning_icon"}, color = "white"},
  -- Phase 5 M2 war (scripts/warsupply.lua, capture.lua, garrison.lua)
  ["supply-low"] = {icons = {"item/rts-supply-crate", "utility/warning_icon"}, color = "yellow"},
  ["supply-out"] = {icons = {"item/rts-supply-crate", "utility/danger_icon"}, color = "red",
                    sound = "utility/alert_destroyed"},
  ["city-subdued"] = {icons = {"item/rts-city-charter", "utility/danger_icon"}, color = "red",
                      sound = "utility/alert_destroyed"},
  ["city-captured"] = {icons = {"item/rts-city-charter", "utility/check_mark_green"}, color = "green"},
  ["troop-wagon-lost"] = {icons = {"item/rts-troop-wagon-kit", "utility/danger_icon"}, color = "red",
                          sound = "utility/alert_destroyed"},
  -- Phase 5 M3 war2 (scripts/belts.lua, scripts/trainswar.lua)
  ["belt-built"] = {icons = {"item/rts-wall", "utility/check_mark_green"}, color = "green"},
  ["belt-waiting"] = {icons = {"item/rts-wall", "utility/warning_icon"}, color = "yellow"},
  ["train-no-shells"] = {icons = {"item/rts-rail-shell", "utility/warning_icon"}, color = "yellow"},
}
P4.ALERT_DEFAULT_STYLE = {icons = {"utility/warning_icon"}, color = "white"}
-- A text that overrides its kind's style: the ruin's previous owner gets kind "ruin-captured" with this text.
P4.ALERT_TEXT_STYLE = {["rts.alert-ruin-lost"] = {icons = {"item/steel-plate", "utility/danger_icon"}, color = "red",
                                                 sound = "utility/alert_destroyed"}}
P4.PING_KINDS = {["base-attacked"] = true, ["hauler-lost"] = true, ["commander-down"] = true}
P4.PING_SIGNALS = {"signal-alert", "signal-red", "signal-dot"} -- the first that exists

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

--- "3 s" / "2.5 с": a recipe time as a localised string.
local function seconds_text(s)
  local number = s == math.floor(s) and string.format("%d", s) or string.format("%.1f", s)
  return {"rts.seconds", number}
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
     and h.minimap and h.minimap.valid and h.build and h.build.valid and h.alerts and h.alerts.valid
     and h.kills and h.kills.valid then
    return h
  end
  return nil
end

-- Sprite paths are checked once (helpers.is_valid_sprite_path); the cache is derived from prototypes only.
local sprite_ok = {}
local function valid_sprite(path)
  local ok = sprite_ok[path]
  if ok == nil then
    ok = helpers.is_valid_sprite_path(path)
    sprite_ok[path] = ok
  end
  return ok
end

local function set_style(element, style)
  if element.style.name ~= style then element.style = style end
end

local function first_sprite(list)
  for _, path in ipairs(list) do
    if valid_sprite(path) then return path end
  end
  return nil
end

--- Icon of a unit prototype: the entity's own icon, else its kit's.
local function unit_sprite(name)
  local u = balance.units[name]
  return first_sprite({"entity/" .. name, u and u.kit and ("item/" .. u.kit) or "entity/" .. name,
                       "utility/questionmark"}) or "utility/questionmark"
end

local function unit_name(name)
  local proto = prototypes.entity[name]
  return proto and proto.localised_name or name
end

local function tech_name(tech)
  if type(tech) == "string" then return {"technology-name." .. tech} end
  return {"rts.tech-unknown"}
end

-- supply.get walks the unit registry (about 33 us at 100 units, docs/qa/phase4-research-notes.md): once per force
-- and tick, shared by the players of a force. Derived from game state only, so every client computes the same.
local supply_cache = {}
local function supply_of(force_name)
  local c = supply_cache[force_name]
  if c and c.tick == game.tick then return c end
  local got = supply.get(force_name)
  c = {tick = game.tick, used = got.used, cap = got.cap}
  supply_cache[force_name] = c
  return c
end

--- Why the force cannot use a recipe yet: the technology name, true (locked, technology unknown) or false. A recipe
--- the force has disabled is locked (laser turret, steam plant); so is a barracks kit whose unit research has not
--- unlocked: its recipe stays enabled, and research.gate would keep every such kit in the barracks output.
local function recipe_lock(force, recipe_name)
  local fr = force.recipes[recipe_name]
  if fr and not fr.enabled then return research.lock_of(recipe_name) or true end
  local unit = KIT_UNIT[recipe_name]
  if unit and not research.is_unlocked(force.name, unit) then return research.lock_of(unit) or true end
  return false
end

--- Switch the vanilla entity tooltip off (HIDE_ENTITY_TOOLTIP). Checked on every full refresh, because a
--- controller change may restore game view settings; logs only when it changed something.
local function apply_view_settings(player)
  if not HIDE_ENTITY_TOOLTIP then return end
  local gvs = player.game_view_settings
  if not gvs.show_entity_tooltip then return end
  gvs.show_entity_tooltip = false
  -- GameViewSettings is a LuaStruct; if the read returned a detached copy, write the whole struct back.
  if player.game_view_settings.show_entity_tooltip then player.game_view_settings = gvs end
  util.log("hud: vanilla entity tooltip hidden for player %d (the top-right corner is the HUD minimap's)",
    player.index)
end

---------------------------------------------------------------------------
-- Recipes (derived from prototypes only, so the caches are identical on every client)
---------------------------------------------------------------------------
local recipe_by_item     -- [item name] = LuaRecipePrototype of the rts recipe that makes it
local recipes_by_machine = {} -- [entity name] = {LuaRecipePrototype...} sorted like the crafting menu

local function recipe_for(item)
  if not recipe_by_item then
    recipe_by_item = {}
    for _, r in pairs(prototypes.recipe) do
      local product = r.products and r.products[1]
      if util.recipe_in(r, RTS_CATEGORIES) and not r.parameter and product and product.type == "item"
         and not recipe_by_item[product.name] then
        recipe_by_item[product.name] = r
      end
    end
  end
  return recipe_by_item[item]
end

-- Sort key of a recipe as in the crafting menu: group order, subgroup order, recipe order, name.
local function recipe_sort_key(r)
  local group, subgroup = r.group, r.subgroup
  return string.format("%s\0%s\0%s\0%s", group and group.order or "", subgroup and subgroup.order or "",
    r.order or "", r.name)
end

local function machine_recipes(entity)
  local list = recipes_by_machine[entity.name]
  if list then return list end
  list = {}
  -- Every crafting machine also lists the "parameters" category (the blueprint parameter recipes 0-9, seen in
  -- the first GUI run as ten purple buttons on the barracks): those recipes are skipped.
  local categories = entity.prototype.crafting_categories or {}
  local keys = {}
  for _, r in pairs(prototypes.recipe) do
    if util.recipe_in(r, categories) and not r.parameter and not r.hidden and not HIDDEN_KITS[r.name] then
      list[#list + 1] = r
      keys[r.name] = recipe_sort_key(r)
    end
  end
  table.sort(list, function(a, b) return keys[a.name] < keys[b.name] end)
  recipes_by_machine[entity.name] = list
  return list
end

-- "[item=iron-plate] 10  [item=copper-plate] 2" (icons and numbers only, so it needs no translation)
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

--- Existing items of one build tab (all tabs when nil), in button order.
local function build_items(tab)
  local list = {}
  for _, item in ipairs(tab and tab.items or BUILD_ITEMS) do
    if prototypes.item[item] and (not P4.NATION_ONLY[item] or P4.nation()) then list[#list + 1] = item end
  end
  return list
end

--- Research lock of a build-menu item: the lock of its rts recipe (see recipe_lock), false without a recipe.
local function item_lock(force, item)
  local recipe = recipe_for(item)
  return recipe and recipe_lock(force, recipe.name) or false
end

-- Phase 5 M1 QA round 1: an item that places an entity of another name (the City charter places a City Center) says
-- so in its build and recipe tooltips: {"", tooltip, "\n", "Builds a [entity] City Center."}.
local OIL_NOTES = {["rts-pumpjack"] = "rts-ux.note-pumpjack", ["rts-refinery"] = "rts-ux.note-refinery",
                    ["rts-chemical-plant"] = "rts-ux.note-chemical-plant"} -- #28: no pipes
local function with_places_note(tooltip, item)
  if OIL_NOTES[item] then tooltip = {"", tooltip, "\n", {OIL_NOTES[item]}} end
  local proto = item and prototypes.item[item]
  local place = proto and proto.place_result
  if not (place and place.name ~= item) then return tooltip end
  return {"", tooltip, "\n", {"rts.tooltip-places", "[entity=" .. place.name .. "]", place.localised_name}}
end

--- 0.1.2 (#30): the name of the tooltip's first line followed by the one-line description of what the item builds, so
--- the player knows what he is about to build. The locale string wraps __1__ in a bold font: close it, write the
--- description on its own line and reopen it.
local function name_with_description(item)
  local proto = prototypes.item[item]
  local place = proto.place_result
  local desc = {"?", place and {"entity-description." .. place.name} or {"item-description." .. item}, ""}
  return {"", proto.localised_name, "[/font]\n[color=0.78,0.78,0.78]", desc, "[/color][font=default-bold]"}
end

local function build_tooltip(item, in_network, lock)
  local recipe = recipe_for(item)
  local how = recipe and {"rts.build-recipe", cost_text(recipe), product_amount(recipe), seconds_text(recipe.energy)}
    or {"rts.build-no-recipe"}
  if lock then
    return with_places_note({"rts.build-tooltip-locked", name_with_description(item),
                             {"rts.in-stock", in_network}, how, tech_name(lock)}, item)
  end
  return with_places_note({"rts.build-tooltip", name_with_description(item), {"rts.in-stock", in_network},
                           how}, item)
end

--- Recipe button tooltip; barracks kits add the unit's supply cost, locked recipes the technology.
local function recipe_tooltip(recipe, lock)
  local unit = KIT_UNIT[recipe.name]
  local base = unit and {"rts.recipe-tooltip-unit", recipe.localised_name, cost_text(recipe),
                         seconds_text(recipe.energy), supply.cost(unit)}
    or {"rts.recipe-tooltip", recipe.localised_name, cost_text(recipe), seconds_text(recipe.energy)}
  local product = recipe.products and recipe.products[1]
  if product and product.type == "item" then base = with_places_note(base, product.name) end
  if lock then return {"rts.recipe-locked-tooltip", base, tech_name(lock)} end
  return {"", base, "\n", {"rts.recipe-queue-hint"}} -- Release 0.1.2 (#22)
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
  h.build.location = {res.width - px(BUILD_WIDTH, s) - m,
                      res.height - px(BUILD_HEIGHT + (h.build_extra_rows or 0) * P4.BUILD_ROW, s) - m}
  -- Centred, but never under the minimap (at large UI scales on narrow windows the centred strip would reach it).
  local sw = px(STRIP_WIDTH, s)
  local sx = math.floor((res.width - sw) / 2 + 0.5)
  sx = math.max(m, math.min(sx, mx - pad - m - sw))
  h.strip.location = {sx, m}
  -- Phase 4: alert lines centred under the strip, kill feed in the top-left corner.
  local aw = px(P4.ALERT_WIDTH, s)
  local ax, ay = sx + math.floor((sw - aw) / 2 + 0.5), m + px(STRIP_HEIGHT, s) + px(4, s)
  h.alerts.location = {ax, ay}
  h.kills.location = {m, m}
  util.log("hud: layout player=%d display %dx%d scale %.2f: panel (%d, %d) %dx%d, build (%d, %d) %dx%d, "
    .. "strip (%d, %d) %dx%d, minimap (%d, %d) %dx%d, alerts (%d, %d) %d wide, kill feed (%d, %d) %d wide",
    player.index, res.width, res.height, s,
    m, res.height - px(PANEL_HEIGHT, s) - m, px(PANEL_WIDTH, s), px(PANEL_HEIGHT, s),
    res.width - px(BUILD_WIDTH, s) - m, res.height - px(BUILD_HEIGHT, s) - m, px(BUILD_WIDTH, s), px(BUILD_HEIGHT, s),
    sx, m, sw, px(STRIP_HEIGHT, s), mx, m + pad, px(MINIMAP_SIZE, s), px(MINIMAP_SIZE, s), ax, ay, aw, m, m,
    px(P4.KILL_WIDTH, s))
end

--- 0.1.1 (issue #16): the free strip of the top edge between the match strip and the minimap frame, in display
--- pixels: x, width and the margin (scripts/objectives.lua puts the objective strip there). Mirrors place().
function hud.top_gap(player)
  local res, s = player.display_resolution, player.display_scale
  local m = px(MARGIN, s)
  local pad = px(MINIMAP_PADDING, s)
  local mx = res.width - px(MINIMAP_SIZE, s) - pad - m
  local sw = px(STRIP_WIDTH, s)
  local sx = math.max(m, math.min(math.floor((res.width - sw) / 2 + 0.5), mx - pad - m - sw))
  local left = sx + sw + m
  return left, (mx - pad - m) - left, m
end

local function add_filler(parent)
  return parent.add({type = "empty-widget", style = "rts_hud_filler"})
end

local function vflow(parent, spacing)
  local flow = parent.add({type = "flow", direction = "vertical"})
  flow.style.vertical_spacing = spacing or 4
  return flow
end

-- Units page, four rows:
--   "6 units selected" (one prototype: "Raider ×6") ........ "HP 100%"  "Order: Idle"
--   [card][card][card] (icon, count, HP bar) ............ Groups [1: 6] [2] [3] [4] [5]
--   [Attack-move [F]] [Stop [X]] [Hold [H]] [Select all [Ctrl+A]]
--   hint line
-- (The abilities agent's buttons live in their own frame, scripts/abilitygui.lua.)
local function build_unit_page(panel, h)
  local el = h.el
  local page = vflow(panel)
  el.unit_page = page

  local header = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.sel_count = header.add({type = "label", style = "rts_hud_heading_label"})
  el.sel_count.style.maximal_width = 200
  add_filler(header)
  el.health = header.add({type = "label", style = "rts_hud_mono_label", tooltip = {"rts.hp-tooltip"}})
  el.order = header.add({type = "label", style = "rts_hud_label", tooltip = {"rts.order-tooltip"}})
  el.order.style.maximal_width = 250 -- "Order: Idle 6 / Commander 1" was cut at 200 (Phase 4 QA)
  -- Phase 5 M2 integration: Disband (Nation mode only; demolish.disband, two presses)
  el.disband = header.add({type = "sprite-button", name = PREFIX .. "disband", sprite = "utility/trash",
                           style = "tool_button_red", tooltip = {"rts.disband-tooltip"}, tags = {rts_hud = "disband"}})
  el.disband.style.size = 24
  el.disband.visible = false

  local kinds_row = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.cards = kinds_row.add({type = "flow", direction = "horizontal"})
  el.cards.style.horizontal_spacing = P4.CARD_SPACING
  el.cards.style.width = P4.CARDS_WIDTH
  el.cards.style.height = P4.CARD_SIZE + 6
  add_filler(kinds_row)
  kinds_row.add({type = "label", style = "rts_hud_dim_label", caption = {"rts.groups"}})
  for n = 1, GROUP_COUNT do
    h.groups[n] = kinds_row.add({type = "button", name = PREFIX .. "group_" .. n, style = "rts_hud_group_button",
                                 caption = tostring(n), tags = {rts_hud = "group", group = n}})
  end

  local commands = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  for _, c in ipairs(COMMANDS) do
    el["cmd_" .. c.action] = commands.add({
      type = "button", name = PREFIX .. "cmd_" .. c.action, style = "rts_hud_button",
      caption = {"rts.button-key", {c.caption}, c.key},
      tooltip = {"rts.cmd-tooltip", {c.caption}, c.key, {c.tooltip}},
      tags = {rts_hud = c.action}})
  end

  el.hint = page.add({type = "label", style = "rts_hud_dim_label", caption = {"rts.sel-hint"}})
  el.hint.style.maximal_width = PANEL_INNER
end

-- Building page:
--   "Barracks #971" ............................................ "HP 1500/1500"
--   [Pause][recipe][recipe][recipe][recipe][recipe]   status line ("Walker kit: running")
--   [recipe]...                     (6 per row)        progress bar
--                                                      counters, or why a kit waits (research / supply)
--                                                      rally point / hint
-- The factory (Phase 4, 25 recipes): the grid takes the whole width, 14 per row, and the status, progress and
-- counters go to one line under it. Kinds without recipes hide the grid and the text column takes the whole width.
local function new_recipe_grid(el, columns)
  if el.b_buttons and el.b_buttons.valid then el.b_buttons.destroy() end
  local grid = el.b_body.add({type = "table", column_count = columns, index = 1})
  grid.style.horizontal_spacing = RECIPE_SPACING
  grid.style.vertical_spacing = RECIPE_SPACING
  grid.style.minimal_width = RECIPE_GRID_WIDTH -- the text column starts at the same x for every barracks
  el.b_buttons = grid
  el.b_columns = columns
  return grid
end

local function build_building_page(panel, h)
  local el = h.el
  local page = vflow(panel, 3)
  page.visible = false
  el.bld_page = page

  local header = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.b_name = header.add({type = "label", style = "rts_hud_heading_label"})
  -- Phase 5 E1: the factory's category tabs (Nation mode)
  el.b_tabs = header.add({type = "flow", direction = "horizontal"})
  el.b_tabs.style.horizontal_spacing = 2
  el.b_tabs.style.left_margin = 8
  el.b_tabs.visible = false
  add_filler(header)
  el.b_hp = header.add({type = "label", style = "rts_hud_mono_label", tooltip = {"rts.health"}})
  -- 0.1.2 (#30): the pinned help card of this building (scripts/helpgui.lua reads tags.rts_help)
  el.b_help = header.add({type = "button", name = PREFIX .. "help_card", style = "rts_hud_button", caption = "?",
                          tooltip = {"rts-help.card-pin-tooltip"}, tags = {rts_help = ""}})
  el.b_help.style.height = P4.DEMOLISH_HEIGHT
  el.b_help.style.minimal_width = P4.DEMOLISH_HEIGHT
  -- Release 0.1.2: Rotate, for the piece page (belts, inserters, ghosts; scripts/pieces.lua)
  el.b_rotate = header.add({type = "button", name = PREFIX .. "rotate_piece", style = "rts_hud_button",
                            caption = {"rts.piece-rotate"}, tooltip = {"rts.piece-rotate-tooltip"},
                            tags = {rts_hud = "rotate_piece"}})
  el.b_rotate.style.height = P4.DEMOLISH_HEIGHT
  el.b_rotate.visible = false
  -- Demolish: two presses (first arms, second within 3 s executes); scripts/demolish.lua
  el.b_demolish = header.add({type = "button", name = PREFIX .. "demolish", style = "rts_hud_button",
                              caption = {"rts.demolish"}, tags = {rts_hud = "demolish"}})
  el.b_demolish.style.height = P4.DEMOLISH_HEIGHT

  local body = page.add({type = "flow", direction = "horizontal"})
  body.style.horizontal_spacing = BODY_SPACING
  el.b_body = body
  new_recipe_grid(el, RECIPE_COLUMNS)
  local text = vflow(body, 2)
  el.b_text = text
  el.b_line1 = text.add({type = "label", style = "rts_hud_label"})
  el.b_progress = text.add({type = "progressbar", style = "rts_hud_progressbar", value = 0,
                            tooltip = {"rts.progress-tooltip"}})
  el.b_line2 = text.add({type = "label", style = "rts_hud_label"})
  el.b_line3 = text.add({type = "label", style = "rts_hud_dim_label"})
  -- Long descriptions wrap to a second line instead of ending in "..." (Phase 4 QA); the texts are kept to two lines.
  el.b_line2.style.single_line = false
  el.b_line3.style.single_line = false

  -- Factory status line (under its full-width grid)
  local foot = page.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  foot.visible = false
  el.b_foot = foot
  el.f_line1 = foot.add({type = "label", style = "rts_hud_label"})
  el.f_line1.style.maximal_width = P4.FACTORY_STATUS_WIDTH
  el.f_progress = foot.add({type = "progressbar", style = "rts_hud_progressbar", value = 0,
                            tooltip = {"rts.progress-tooltip"}})
  el.f_progress.style.width = P4.FACTORY_PROGRESS_WIDTH
  add_filler(foot)
  el.f_line2 = foot.add({type = "label", style = "rts_hud_dim_label"})
  el.f_line2.style.maximal_width = P4.FACTORY_COUNTS_WIDTH
  -- #28: the refinery / chemical plant say how oil moves (no pipes)
  el.f_hint = page.add({type = "label", style = "rts_hud_dim_label"})
  el.f_hint.style.single_line = false
  el.f_hint.visible = false
end

-- Width of the building page's text column: next to the recipe grid, or the whole panel without it.
local function set_text_width(el, width)
  if el.text_width == width then return end
  el.text_width = width
  for _, key in pairs({"b_line1", "b_line2", "b_line3"}) do el[key].style.maximal_width = width end
  el.b_progress.style.width = width
end

local function build_panel(screen, h)
  local panel = screen.add({type = "frame", name = NAMES.panel, direction = "vertical", style = "rts_hud_frame"})
  panel.style.width = PANEL_WIDTH
  panel.style.height = PANEL_HEIGHT
  h.panel = panel
  build_unit_page(panel, h)
  build_building_page(panel, h)
  set_text_width(h.el, PANEL_INNER)
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
  el.timer = row.add({type = "label", style = "rts_hud_timer_label", caption = "--:--", tooltip = {"rts.match-time"}})
  el.own = row.add({type = "label", style = "rts_hud_mono_label", tooltip = {"rts.own-units-tooltip"}})
  el.own.style.font_color = COLOR.own
  row.add({type = "label", style = "rts_hud_dim_label", caption = {"rts.versus"}})
  el.enemy = row.add({type = "label", style = "rts_hud_mono_label", tooltip = {"rts.enemy-units-tooltip"}})
  el.enemy.style.font_color = COLOR.enemy
  -- Phase 4: supply used / cap (supply.get)
  el.supply = row.add({type = "label", style = "rts_hud_mono_label", tooltip = {"rts.supply-tooltip"}})
  el.supply.style.left_margin = 6
  -- Phase 4: research panel (techgui.lua, T) and How to play (F11)
  local function strip_button(name, caption, tooltip, action, left_margin)
    local b = row.add({type = "button", name = PREFIX .. name, caption = caption, tooltip = tooltip,
                       tags = {rts_hud = action}})
    b.style.height = 24
    b.style.minimal_width = 0
    b.style.padding = {0, 6}
    b.style.font = "default-semibold"
    if left_margin then b.style.left_margin = left_margin end
    return b
  end
  el.research = strip_button("research", {"rts.button-key", {"rts.research-button"}, "T"},
    {"rts.research-button-tooltip"}, "research", 6)
  el.help = strip_button("help", "?", {"rts.help-button-tooltip"}, "help")
  -- Phase 5 M1: territory share as a button that shows / hides the city list (Nation mode only, see update_strip)
  el.cities = strip_button("cities", "", {"rts.territory-share-tooltip"}, "cities")
  el.cities.visible = false
  -- Phase 3: the match menu (lobby.lua); F10 does the same.
  el.menu = row.add({type = "button", name = PREFIX .. "menu", caption = {"rts.menu-button"},
                     tooltip = {"rts.menu-button-tooltip"}, tags = {rts_hud = "menu"}})
  el.menu.style.height = 24
  el.menu.style.minimal_width = 64
  el.menu.style.padding = {0, 6}
  el.menu.style.font = "default-semibold"

  local res = strip.add({type = "flow", direction = "horizontal", style = "rts_hud_centered_row"})
  res.style.horizontal_spacing = 8
  h.res = {}
  for _, r in ipairs(RESOURCES) do
    if valid_sprite(r.sprite) then h.res[r.key] = resource_pair(res, r.sprite, {r.tooltip}) end
  end
  local power_tip = {"rts.power-tooltip"}
  local power, pair = resource_pair(res, "tooltip-category-electricity", power_tip) -- core SpritePrototype
  h.res.power = power
  h.res.power_sat = pair.add({type = "label", style = "rts_hud_mono_label", caption = "", tooltip = power_tip})
  h.res.bots = resource_pair(res, "item/construction-robot", {"rts.bots-tooltip"})
  -- Phase 5 M2 treasury: "₡ 1,240 (+35/min)" (scripts/treasury.lua); a click opens the market (Nation mode only)
  el.treasury = res.add({type = "label", name = PREFIX .. "treasury", style = "rts_hud_mono_label", caption = "",
                         tags = {rts_hud = "market"}})
  el.treasury.visible = false

  local message_row = strip.add({type = "flow", direction = "horizontal", style = "rts_hud_centered_row"})
  el.message = message_row.add({type = "label", style = "rts_hud_message_label"})
  el.message.style.maximal_width = STRIP_INNER
end

local function build_tab(player_index)
  local key = prefs(player_index).build_tab
  local tab = BUILD_TAB_BY_KEY[key]
  if tab and tab.nation and not P4.nation() then tab = nil end -- Phase 5: the Age II tab exists in Nation mode only
  return tab or BUILD_TABS[1]
end

--- (Re)fill the build grid with the buttons of the player's current tab.
local function fill_build_grid(player_index, h)
  local grid = h.el.build_grid
  grid.clear()
  h.build_buttons = {}
  local tab = build_tab(player_index)
  for _, item in ipairs(build_items(tab)) do
    h.build_buttons[item] = grid.add({type = "sprite-button", name = PREFIX .. "build_" .. item,
                                      style = "rts_hud_build_button", sprite = "item/" .. item,
                                      tags = {rts_hud = "build", item = item}})
  end
  for key, button in pairs(h.el.build_tabs or {}) do button.toggled = key == tab.key end
  -- Phase 5 E1: a tab with more than BUILD_COLUMNS items takes more rows; the frame grows upwards. Phase 5 M1
  -- integration: the rows of the largest tab in this mode, so the tab row stays put when the tab changes
  local most = 0
  for _, t in ipairs(BUILD_TABS) do
    if not t.nation or P4.nation() then most = math.max(most, #build_items(t)) end
  end
  local extra = math.max(0, math.ceil(most / BUILD_COLUMNS) - 1)
  if h.build_extra_rows ~= extra then
    h.build_extra_rows = extra
    h.build.style.height = BUILD_HEIGHT + extra * P4.BUILD_ROW
    local player = game.get_player(player_index)
    if player then
      local res, sc = player.display_resolution, player.display_scale
      local m = math.floor(MARGIN * sc + 0.5)
      h.build.location = {res.width - math.floor(BUILD_WIDTH * sc + 0.5) - m,
                          res.height - math.floor((BUILD_HEIGHT + extra * P4.BUILD_ROW) * sc + 0.5) - m}
    end
  end
end

-- Build menu: "Build [B]" ...... "Q / right-click: done"; [Economy] [Production] [Defence]; one row of slot buttons.
local function build_build_menu(screen, h, player_index)
  local frame = screen.add({type = "frame", name = NAMES.build, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = BUILD_WIDTH
  frame.style.height = BUILD_HEIGHT
  h.build = frame
  local header = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  header.add({type = "label", style = "rts_hud_heading_label", caption = {"rts.build-title"},
              tooltip = {"rts.build-title-tooltip"}})
  add_filler(header)
  header.add({type = "label", style = "rts_hud_dim_label", caption = {"rts.build-done-hint"}})
  -- Phase 5 M3 war2: the fort belt tool (F with no unit selected), Nation mode only (the header has room; the tab row
  -- is full with Russian captions)
  local belt = header.add({type = "sprite-button", name = PREFIX .. "fort_belt", style = "rts_hud_tab_button",
    sprite = "item/rts-gate", tooltip = {"rts-war3.belt-button-tooltip"}, tags = {rts_hud = "fort_belt"}})
  belt.style.width = 24
  belt.style.padding = 0
  belt.visible = P4.nation()
  h.el.fort_belt = belt
  local tabs = frame.add({type = "flow", direction = "horizontal"})
  tabs.style.horizontal_spacing = 2
  h.el.build_tabs = {}
  for _, tab in ipairs(BUILD_TABS) do
    if tab.sprite then -- Phase 5 E1: the Age II tab
      local b = tabs.add({type = "sprite-button", name = PREFIX .. "build_tab_" .. tab.key, style = "rts_hud_tab_button",
        sprite = tab.sprite, tooltip = {tab.tooltip}, tags = {rts_hud = "build_tab", tab = tab.key}})
      b.style.width = P4.AGE2_TAB_WIDTH
      b.style.padding = 0
      b.visible = not tab.nation or P4.nation()
      h.el.build_tabs[tab.key] = b
    else
      h.el.build_tabs[tab.key] = tabs.add({type = "button", name = PREFIX .. "build_tab_" .. tab.key,
        style = "rts_hud_tab_button", caption = {tab.caption}, tooltip = {tab.tooltip},
        tags = {rts_hud = "build_tab", tab = tab.key}})
    end
  end
  local grid = frame.add({type = "table", column_count = BUILD_COLUMNS})
  grid.style.horizontal_spacing = 2
  grid.style.vertical_spacing = 2
  h.el.build_grid = grid
  fill_build_grid(player_index, h)
end

-- Alert lines under the strip (Phase 4): P4.ALERT_SHOWN labels, a click on one jumps the camera to its alert.
local function build_alerts(screen, h)
  local frame = screen.add({type = "frame", name = NAMES.alerts, direction = "vertical", style = "rts_hud_feed_frame"})
  frame.style.width = P4.ALERT_WIDTH
  frame.visible = false
  h.alerts = frame
  h.alert_lines = {}
  for i = 1, P4.ALERT_SHOWN do
    local line = frame.add({type = "label", name = PREFIX .. "alert_" .. i, style = "rts_hud_label",
                            tooltip = {"rts.alert-tooltip"}, tags = {rts_hud = "alert", line = i}})
    line.style.maximal_width = P4.ALERT_WIDTH - FRAME_PADDING_X
    line.visible = false
    h.alert_lines[i] = line
  end
end

-- Kill feed in the top-left corner (Phase 4).
local function build_kills(screen, h)
  local frame = screen.add({type = "frame", name = NAMES.kills, direction = "vertical", style = "rts_hud_feed_frame",
                            ignored_by_interaction = true})
  frame.style.width = P4.KILL_WIDTH
  frame.visible = false
  h.kills = frame
  h.kill_lines = {}
  for i = 1, P4.KILL_SHOWN do
    local line = frame.add({type = "label", style = "rts_hud_small_label"})
    line.style.maximal_width = P4.KILL_WIDTH - FRAME_PADDING_X
    line.visible = false
    h.kill_lines[i] = line
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
                         position = MINIMAP_CENTER, zoom = minimap_zoom(), surface_index = util.surface().index,
                         tags = {rts_hud = "minimap"}})
  mm.style.width = MINIMAP_SIZE
  mm.style.height = MINIMAP_SIZE
  mm.bring_to_front()
  h.minimap = mm
end

---------------------------------------------------------------------------
-- Refresh: units page
---------------------------------------------------------------------------
-- Card order: commander, walker, heavy, drone, raider, artillery, hauler; tier 1 before mk2; then by name.
local function card_rank(name)
  local u = balance.units[name]
  local kind = u and u.kind or name
  return (KIND_RANK[kind] or 99) * 10 + (u and u.tier or 1)
end

local function sorted_names(by_name)
  local list = {}
  for name in pairs(by_name) do list[#list + 1] = name end
  table.sort(list, function(a, b)
    local ra, rb = card_rank(a), card_rank(b)
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return list
end

local function order_name(o)
  return ORDER_KEYS[o] and {ORDER_KEYS[o]} or o
end

-- "Idle", or the two most common orders: "Move 8, Idle 4" (plus ", …" when there are more).
local function order_text(orders)
  local list = {}
  for o, c in pairs(orders) do list[#list + 1] = {o, c} end
  table.sort(list, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[1] < b[1]
  end)
  if #list == 0 then return "" end
  if #list == 1 then return order_name(list[1][1]) end
  return {#list > 2 and "rts.order-more" or "rts.order-two", order_name(list[1][1]), list[1][2],
          order_name(list[2][1]), list[2][2]}
end

local function health_color(ratio)
  return ratio >= 0.66 and COLOR.green or (ratio >= 0.33 and COLOR.yellow or COLOR.red)
end

-- Counter wheel line of a card tooltip, from balance.units[name].strong / weak (kinds plus building classes).
local COUNTER_KEYS = {building = "rts.kind-building", turret = "rts.kind-turret",
                      ["laser-turret"] = "rts.kind-laser-turret", wall = "rts.kind-wall"}
for kind, key in pairs(KIND_KEYS) do COUNTER_KEYS[kind] = key end
local counters_cache = {}
local function counters_text(name)
  local cached = counters_cache[name]
  if cached ~= nil then return cached or nil end
  local u = balance.units[name]
  local function list(kinds)
    local out = {""}
    for i, kind in ipairs(kinds or {}) do
      if i > 1 then out[#out + 1] = ", " end
      out[#out + 1] = COUNTER_KEYS[kind] and {COUNTER_KEYS[kind]} or kind
    end
    return #out > 1 and out or "-"
  end
  local text = false
  if u and ((u.strong and #u.strong > 0) or (u.weak and #u.weak > 0)) then
    text = {"rts.card-counters", list(u.strong), list(u.weak)}
  end
  counters_cache[name] = text
  return text or nil
end

--- Rebuild the unit cards when the set of prototypes changed; otherwise update counts, bars and tooltips in place.
--- The Commander's card shows its level as the number (one Commander per force) and level and kills in the tooltip,
--- from commander.card (scripts/commander.lua, the abilities agent's module). Returns number, tooltip line or nil.
local function commander_card(force_name)
  local card_fn = optional_fn("scripts.commander", {"card"})
  local c = card_fn and card_fn(force_name)
  if not (c and c.level) then return nil end
  local line = c.next_kills and {"rts.card-commander", c.level, c.kills or 0, c.next_kills}
    or {"rts.card-commander-max", c.level, c.kills or 0}
  return c.level, line
end

local function update_cards(h, names, by_name, force_name)
  local el = h.el
  local shown = math.min(#names, #names > P4.CARD_MAX and P4.CARD_MAX - 1 or P4.CARD_MAX)
  local key = table.concat(names, " ", 1, shown) .. "|" .. tostring(#names > shown and #names - shown or 0)
  if h.card_key ~= key then
    h.card_key = key
    el.cards.clear()
    h.cards = {}
    for i = 1, shown do
      local name = names[i]
      local card = el.cards.add({type = "flow", direction = "vertical"})
      card.style.vertical_spacing = 1
      local button = card.add({type = "sprite-button", name = PREFIX .. "card_" .. name, style = "rts_hud_card_button",
                               sprite = unit_sprite(name), tags = {rts_hud = "card", unit = name}})
      local bar = card.add({type = "progressbar", style = "rts_hud_card_bar", value = 1})
      h.cards[name] = {button = button, bar = bar}
    end
    if #names > shown then
      local more = el.cards.add({type = "label", style = "rts_hud_label", caption = {"rts.cards-more", #names - shown}})
      local rest = {""}
      for i = shown + 1, #names do
        rest[#rest + 1] = {"rts.kind-count", unit_name(names[i]), by_name[names[i]].n}
        if i < #names then rest[#rest + 1] = "\n" end
      end
      more.tooltip = rest
    end
  end
  for name, card in pairs(h.cards or {}) do
    local d = by_name[name]
    if d and card.button.valid then
      local ratio = d.max > 0 and d.hp / d.max or 1
      card.button.number = d.n
      local tip = {"rts.card-tooltip", unit_name(name), d.n, math.floor(d.hp + 0.5), math.floor(d.max + 0.5),
                   math.floor(ratio * 100 + 0.5), supply.cost(name)}
      if balance.units[name] and balance.units[name].kind == "commander" then
        local level, line = commander_card(force_name)
        if level then
          card.button.number = level
          tip = {"", tip, "\n", line}
        end
      end
      local counters = counters_text(name)
      card.button.tooltip = counters and {"", tip, "\n", counters, "\n", {"rts.card-click-hint"}}
        or {"", tip, "\n", {"rts.card-click-hint"}}
      card.bar.value = math.max(0, math.min(1, ratio))
      card.bar.style.color = health_color(ratio)
    end
  end
end

local function update_units(player, h)
  local el = h.el
  local p = pstate(player.index)
  local selection = p and p.selection
  local n, by_name, orders, health_sum, health_n = 0, {}, {}, 0, 0
  if selection then
    for un in pairs(selection) do
      local rec = live_record(un)
      if rec then
        n = n + 1
        local e = rec.entity
        local d = by_name[e.name]
        if not d then
          d = {n = 0, hp = 0, max = 0}
          by_name[e.name] = d
        end
        d.n = d.n + 1
        d.hp = d.hp + (e.health or 0)
        d.max = d.max + (e.max_health or 0)
        local order = rec.order or units.IDLE
        orders[order] = (orders[order] or 0) + 1
        local ratio = e.get_health_ratio()
        if ratio then
          health_sum, health_n = health_sum + ratio, health_n + 1
        end
      end
    end
  end

  local names = sorted_names(by_name)
  update_cards(h, names, by_name, player.force.name)
  if n == 0 then
    if el.disband and el.disband.valid then el.disband.visible = false end -- Phase 5 M2 integration
    el.sel_count.caption = {"rts.sel-none"}
    el.hint.caption = {"rts.sel-hint-empty"}
    el.health.caption = ""
    el.order.caption = ""
    return n
  end

  -- One prototype: "Raider ×6"; mixed: "9 units selected"
  el.sel_count.caption = #names == 1 and {"rts.kind-count", unit_name(names[1]), n} or {"rts.sel-count", n}
  el.hint.caption = {"rts.sel-hint"}
  if el.disband and el.disband.valid then -- Phase 5 M2 integration: Nation mode only; red while armed
    el.disband.visible = P4.nation()
    local armed_fn = optional_fn("scripts.demolish", {"disband_armed"})
    el.disband.toggled = armed_fn ~= nil and armed_fn(player.index) == true
  end
  if health_n > 0 then
    local avg = health_sum / health_n
    el.health.caption = {"rts.hp-percent", string.format("%3d", math.floor(avg * 100 + 0.5))}
    el.health.style.font_color = health_color(avg)
  else
    el.health.caption = ""
  end
  el.order.caption = {"rts.order", order_text(orders)}
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
      button.tooltip = {"rts.group-tooltip", n, count}
      button.toggled = selection ~= nil and next(selection) ~= nil and same_set(set, selection)
    else
      button.caption = tostring(n)
      button.tooltip = {"rts.group-empty-tooltip", n}
      button.toggled = false
    end
    button.enabled = count > 0
  end
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
  local el = h.el
  local factory = P4.crafter(rec.kind) -- Phase 5 E1: districts too
  local columns = factory and P4.FACTORY_COLUMNS or RECIPE_COLUMNS
  local grid = el.b_columns == columns and el.b_buttons or new_recipe_grid(el, columns)
  grid.clear()
  h.recipe_buttons = {}
  h.recipe_locks = {}
  h.bld_un = un
  if el.f_hint and el.f_hint.valid then el.f_hint.visible = false end
  if rec.kind ~= "barracks" and not factory then
    grid.visible = false
    el.b_text.visible = true
    el.b_foot.visible = false
    set_text_width(el, PANEL_INNER)
    -- Phase 5 M1 integration: the factory's category tabs stayed on every page without recipes (City Center, depot,
    -- rolling stock) after a factory page
    if el.b_tabs and el.b_tabs.valid then
      el.b_tabs.clear()
      el.b_tabs.visible = false
    end
    return
  end
  grid.visible = true
  el.b_text.visible = not factory -- the factory's status is on the line under its full-width grid
  el.b_foot.visible = factory
  set_text_width(el, TEXT_WITH_GRID)
  -- Pause first: same place for every producer, and a new recipe never moves it.
  h.recipe_buttons[""] = grid.add({type = "sprite-button", name = PREFIX .. "recipe_pause",
    style = "rts_hud_recipe_button", sprite = "utility/pause", tooltip = {"rts.pause-tooltip"},
    tags = {rts_hud = "recipe", recipe = ""}})
  if factory and P4.nation() then -- Phase 5 E1: Auto (make targets pick the recipe)
    h.recipe_buttons[P4.AUTO] = grid.add({type = "sprite-button", name = PREFIX .. "recipe_auto",
      style = "rts_hud_recipe_button", sprite = "utility/refresh", tooltip = {"rts.recipe-auto-tooltip"},
      tags = {rts_hud = "recipe", recipe = P4.AUTO}})
  end
  -- Release 0.1.2 (#22): the Endless toggle (a click on a recipe makes endless production, as before 0.1.2, instead
  -- of a counted order). After Pause and Auto so those never move.
  h.recipe_buttons[P4.ENDLESS] = grid.add({type = "sprite-button", name = PREFIX .. "recipe_endless",
    style = "rts_hud_recipe_button", sprite = "utility/status_working", tooltip = {"rts.recipe-endless-tooltip"},
    tags = {rts_hud = "recipe", recipe = P4.ENDLESS}})
  -- Phase 5 E1: a factory in Nation mode shows one category tab at a time
  local tabs = rec.kind == "factory" and P4.nation() and el.b_tabs ~= nil and el.b_tabs.valid
  local tab = tabs and (prefs(player.index).factory_tab or "buildings") or nil
  local tab_flow = el.b_tabs
  if tab_flow and tab_flow.valid then
    tab_flow.clear()
    tab_flow.visible = tabs
    if tabs then
      for _, t in ipairs(P4.FACTORY_TABS) do
        local b = tab_flow.add({type = "sprite-button", name = PREFIX .. "factory_tab_" .. t.key,
          style = "rts_hud_tab_button", sprite = t.sprite, tooltip = {t.tooltip},
          tags = {rts_hud = "factory_tab", tab = t.key}})
        b.style.width = P4.AGE2_TAB_WIDTH
        b.style.height = P4.DEMOLISH_HEIGHT
        b.style.padding = 0
        b.toggled = t.key == tab
      end
    end
  end
  local names = {}
  for _, r in ipairs(machine_recipes(rec.entity)) do
    -- Phase 5 M1/E1: Nation-only and age-locked recipes in Nation mode only; one category per factory tab
    if P4.visible_recipe(r.name) and (not tab or P4.recipe_tab(r) == tab) then
      h.recipe_buttons[r.name] = grid.add({type = "sprite-button", name = PREFIX .. "recipe_" .. r.name,
        style = "rts_hud_recipe_button", sprite = "recipe/" .. r.name, tooltip = recipe_tooltip(r),
        tags = {rts_hud = "recipe", recipe = r.name}})
      h.recipe_locks[r.name] = false
      names[#names + 1] = r.name
    end
  end
  -- QA log line: the button order, left to right and row by row ("hud: recipe buttons barracks#N player=N:
  -- pause rts-walker-kit rts-walker-heavy-kit (6 per row)")
  util.log("hud: recipe buttons %s#%d player=%d: pause %s (%d per row)%s", rec.kind, un, player.index,
    table.concat(names, " "), columns, tab and (", tab " .. tab) or "")
end

--- Grey out the recipe buttons the force cannot use yet and mark the active one. Called on every panel refresh,
--- so a technology finishing while the panel is open unlocks its button. QA log line when a lock changes:
--- "hud: recipe locks <kind>#N player=N: <recipe>=<tech|locked|open> ...".
local function update_recipe_buttons(player, h, rec, active)
  local force = player.force
  local changed
  for name, button in pairs(h.recipe_buttons or {}) do
    if button.valid then
      local special = name == "" or name == P4.AUTO or name == P4.ENDLESS
      local lock = not special and recipe_lock(force, name) or false
      local style = name == active and "rts_hud_recipe_button_active"
        or (lock and "rts_hud_recipe_button_locked" or "rts_hud_recipe_button")
      set_style(button, style)
      if not special and h.recipe_locks[name] ~= lock then
        h.recipe_locks[name] = lock
        button.enabled = not lock or name == active
        button.tooltip = recipe_tooltip(prototypes.recipe[name], lock)
        changed = changed or {}
        changed[#changed + 1] = string.format("%s=%s", name, lock == false and "open"
          or (type(lock) == "string" and lock or "locked"))
      end
    end
  end
  if changed then
    table.sort(changed)
    util.log("hud: recipe locks %s#%d player=%d: %s", rec.kind, rec.entity.unit_number, player.index,
      table.concat(changed, " "))
  end
end

-- "waiting for [item=iron-plate] [item=copper-plate]" from production's pull state.
local function state_text(state)
  if not state or state == "supplied" then return {"rts.state-running"} end
  local short = string.match(state, "^starved: (.+)$")
  if short then
    local icons = {}
    for name in string.gmatch(short, "[^,]+") do icons[#icons + 1] = "[item=" .. name .. "]" end
    return {"rts.state-waiting", table.concat(icons, " ")}
  end
  if state == "no network" then return {"rts.state-no-network"} end
  if state == "idle" then return {"rts.state-idle"} end
  return state
end

-- The vanilla entity status text (entity-status.<name> in the core locale), e.g. "Working".
local function status_name(entity)
  local custom = entity.custom_status -- Phase 5 M2 people: "No workers" (scripts/labor.lua)
  if custom then return custom.label end
  local status = entity.status
  if not status then return "-" end
  local name = util.define_name(defines.entity_status, status)
  return {"?", {"entity-status." .. string.gsub(name, "_", "-")}, (string.gsub(name, "_", " "))}
end

--- Why the barracks holds a kit (research.block_of): a localised line and its tooltip, or nil.
local function block_text(un)
  local b = research.block_of(un)
  if not b then return nil end
  local unit = b.unit and unit_name(b.unit) or "?"
  if b.reason == "locked" then
    return {"rts.barracks-blocked-research", tech_name(b.tech or true), unit},
           {"rts.barracks-blocked-research-tooltip", unit, tech_name(b.tech or true)}
  elseif b.reason == "supply" then
    return {"rts.barracks-blocked-supply", b.used or 0, b.cap or 0, unit},
           {"rts.barracks-blocked-supply-tooltip", unit, supply.cost(b.unit or ""), b.used or 0, b.cap or 0}
  elseif b.reason == "surcharge" then -- Phase 5 E1: the army soft cap (production.lua)
    local pct = math.floor(((b.mult or 1) - 1) * 100 + 0.5)
    return {"rts.barracks-blocked-surcharge", pct, "[item=" .. tostring(b.item) .. "]", unit},
           {"rts.barracks-blocked-surcharge-tooltip", unit, pct}
  elseif b.reason == "age" then -- Phase 5 E1: an Age II unit before Age II
    return {"rts.barracks-blocked-age", unit}, {"rts.barracks-blocked-age-tooltip", unit}
  elseif b.reason == "recruits" then -- Phase 5 M2 people: the barracks' city has no worker to draft (scripts/labor.lua)
    return {"rts-people.barracks-blocked-recruits", unit, b.have or 0, b.need or 1},
           {"rts-people.barracks-blocked-recruits-tooltip", unit, b.need or 1}
  elseif b.reason == "unpaid" then -- Phase 5 M2 treasury: wages unpaid (debt stage 2 or 3)
    return {"rts-treasury.barracks-unpaid", unit}, {"rts-treasury.barracks-unpaid-tooltip", unit}
  elseif b.reason == "airfield" then -- Phase 5 M3 air: a plane kit needs an airfield in the barracks' city
    return {"rts-air.barracks-no-airfield", unit}, {"rts-air.barracks-no-airfield-tooltip", unit}
  end
  return {"rts.barracks-blocked-other", tostring(b.reason)}, ""
end

local OIL_HINTS = {["rts-refinery"] = "rts-ux.refinery-hint", ["rts-chemical-plant"] = "rts-ux.chem-hint"}
local function update_producer(player, h, un, rec)
  local el = h.el
  local factory = P4.crafter(rec.kind) -- Phase 5 E1: districts too
  local line1, progress = factory and el.f_line1 or el.b_line1, factory and el.f_progress or el.b_progress
  local st = production.status(un) or {}
  local recipe = st.recipe and prototypes.recipe[st.recipe]
  if recipe then
    line1.caption = {"rts.producer-line", "[recipe=" .. recipe.name .. "]", recipe.localised_name, state_text(st.state)}
    line1.style.font_color = (st.state or ""):find("^starved") and COLOR.yellow or COLOR.white
  else
    line1.caption = {"rts.paused"}
    line1.style.font_color = COLOR.dim
  end
  if st.queue then -- Release 0.1.2 (#22): "Extractor 2 / 5" (crafts left of the order)
    line1.caption = {"rts.recipe-queue-line", line1.caption, st.queue.remaining, st.queue.total}
  end
  if st.auto then line1.caption = {"rts.recipe-auto-line", line1.caption} end -- Phase 5 E1
  progress.visible = recipe ~= nil
  progress.value = math.max(0, math.min(1, st.progress or 0))
  update_recipe_buttons(player, h, rec, st.recipe or "")
  for name, button in pairs(h.recipe_buttons or {}) do -- the remaining count on the ordered recipe's button
    if button.valid and name ~= "" and name ~= P4.AUTO and name ~= P4.ENDLESS then
      local n = st.queue and st.queue.recipe == name and st.queue.remaining or nil
      if button.number ~= n then button.number = n end
    end
  end
  local endless_button = h.recipe_buttons and h.recipe_buttons[P4.ENDLESS]
  if endless_button and endless_button.valid then
    set_style(endless_button, prefs(player.index).endless and "rts_hud_recipe_button_active" or "rts_hud_recipe_button")
  end
  local auto_button = h.recipe_buttons and h.recipe_buttons[P4.AUTO]
  if auto_button and auto_button.valid then
    set_style(auto_button, st.auto and "rts_hud_recipe_button_active" or "rts_hud_recipe_button")
  end
  local stats = production.stats(rec.force)
  if not factory then
    -- Phase 4: a kit waiting for research or for supply takes the counters' line (research.block_of).
    local blocked, tip = block_text(un)
    if blocked then
      el.b_line2.style.font_color = COLOR.red
      el.b_line2.caption = blocked
      el.b_line2.tooltip = tip
    else
      el.b_line2.style.font_color = COLOR.white
      el.b_line2.caption = {"rts.barracks-made", st.spawned or 0, stats.walkers}
      el.b_line2.tooltip = {"rts.barracks-made-tooltip", stats.kits, stats.walkers, stats.heavies}
      -- Phase 5 M1 integration: the army soft cap's surcharge whenever the army is past its free share (Nation mode),
      -- the paid state included; +0 % below the first step
      local past, mult = false, 1
      if production.army_past_free then past, mult = production.army_past_free(rec.force) end
      if past then
        local pct = math.floor((mult - 1) * 100 + 0.5)
        el.b_line2.style.font_color = COLOR.yellow
        el.b_line2.caption = {"rts.barracks-made-surcharge", st.spawned or 0, stats.walkers, pct}
        el.b_line2.tooltip = {"rts.barracks-surcharge-tooltip", pct}
      end
    end
    el.b_line3.caption = rec.rally and {"rts.rally-set", util.pos_str(rec.rally)} or {"rts.rally-none"}
    el.b_line3.tooltip = {"rts.rally-tooltip"}
  else
    -- this factory's own counters (production.lua rec.made / rec.moved), not the force's totals
    el.f_line2.caption = {"rts.factory-made-short", rec.made or 0, rec.moved or 0}
    el.f_line2.tooltip = {"", {"rts.factory-made", rec.made or 0, rec.moved or 0}, "\n", {"rts.factory-hint"}}
    local hint = OIL_HINTS[rec.entity.name]
    if el.f_hint and el.f_hint.valid then
      el.f_hint.visible = hint ~= nil
      if hint then el.f_hint.caption = {hint} end
    end
  end
end

local function update_cc(player, h, un, rec)
  local el = h.el
  local snap = snapshot(rec.force)
  el.b_progress.visible = false
  el.b_line2.tooltip, el.b_line3.tooltip = "", ""
  if not snap then
    el.b_line1.caption, el.b_line2.caption, el.b_line3.caption = "", "", ""
    return
  end
  el.b_line1.caption = {"rts.cc-robots", snap.construction_idle, snap.construction_total, snap.logistic_idle,
                        snap.logistic_total}
  el.b_line1.style.font_color = COLOR.white
  el.b_line2.caption = {"rts.cc-power", string.format("%.2f", snap.power_demand / 1e6),
                        string.format("%.2f", snap.power_capacity / 1e6),
                        math.floor(snap.power_satisfaction * 100 + 0.5)}
  el.b_line2.style.font_color = snap.power_satisfaction < 0.9 and COLOR.red or COLOR.white
  local proto = rec.entity.prototype
  el.b_line3.caption = {"rts.cc-range", proto.construction_radius or 0, proto.logistic_radius or 0}
end

local function update_other(player, h, un, rec)
  local el = h.el
  local e = rec.entity
  el.b_progress.visible = false
  el.b_line1.caption = {"rts.status", status_name(e)}
  el.b_line1.style.font_color = e.status == defines.entity_status.working and COLOR.white or COLOR.yellow
  el.b_line2.style.font_color = COLOR.white
  el.b_line2.tooltip, el.b_line3.tooltip = "", ""
  el.b_line3.caption = ""
  if rec.kind == "turret" then
    local ammo = e.get_inventory(defines.inventory.turret_ammo)
    local n = ammo and ammo.get_item_count(production.AMMO) or 0
    local snap = snapshot(rec.force)
    local feed = rec.feed_state
    local feed_text = feed and (FEED_KEYS[feed] and {FEED_KEYS[feed]} or feed) or {"rts.turret-not-fed"}
    el.b_line1.caption = {"rts.turret-ammo", n, feed_text}
    el.b_line1.style.font_color = n > 0 and COLOR.white or COLOR.red
    el.b_line2.caption = {"rts.turret-network", snap and snap.magazines or 0}
    el.b_line3.caption = {"rts.turret-hint"}
  elseif rec.kind == "extractor" then
    local target = e.mining_target
    el.b_line2.caption = target and {"rts.extractor-mining", "[entity=" .. target.name .. "]", target.localised_name}
      or {"rts.extractor-no-ore"}
    el.b_line3.caption = {"rts.extractor-hint"}
  elseif rec.kind == "pumpjack" then -- #28: oil travels through the network as items (scripts/districts.lua drain)
    if rec.pump_state == "no network" then
      el.b_line1.caption = {"rts.status", {"rts.state-no-network"}}
      el.b_line1.style.font_color = COLOR.red
      el.b_line2.caption = {"rts-ux.pump-no-network"}
      el.b_line2.style.font_color = COLOR.red
    else
      el.b_line2.caption = {"rts-ux.pump-line", string.format("%.0f", (rec.pump_rate or 0))}
    end
    el.b_line3.caption = {"rts-ux.pump-hint"}
  elseif rec.kind == "smelter" then
    local recipe = e.get_recipe()
    local name = recipe and recipe.name
    if not name then
      local previous = e.previous_recipe -- RecipeIDAndQualityIDPair: name is a LuaRecipePrototype on read
      local id = previous and previous.name
      name = id and (type(id) == "string" and id or id.name)
    end
    local proto = name and prototypes.recipe[name]
    el.b_line2.caption = proto and {"rts.smelter-recipe", "[recipe=" .. name .. "]", proto.localised_name}
      or {"rts.smelter-waiting"}
    el.b_line3.caption = {"rts.smelter-hint"}
  elseif rec.kind == "stockpile" then
    local inv = e.get_inventory(defines.inventory.chest)
    el.b_line2.caption = {"rts.stockpile-holds", inv and inv.get_item_count() or 0}
  elseif rec.kind == "solar" then
    local kw = math.floor(e.prototype.get_max_energy_production(e.quality) * 60 / 1000 + 0.5)
    el.b_line2.caption = {"rts.solar-hint", kw}
  -- Phase 4 buildings
  elseif rec.kind == "laser-turret" then
    local size = e.electric_buffer_size or 0
    local charge = size > 0 and math.floor(math.min(1, e.energy / size) * 100 + 0.5) or 0
    el.b_line1.caption = {"rts.laser-charge", charge}
    el.b_line1.style.font_color = charge >= 50 and COLOR.white or COLOR.yellow
    el.b_line2.caption = {"rts.laser-hint"}
    el.b_line3.caption = {"rts.laser-hint-2"}
  elseif rec.kind == "wall" then
    el.b_line2.caption = {"rts.wall-hint"}
  elseif rec.kind == "steam-plant" then
    local fuel = e.get_fuel_inventory and e.get_fuel_inventory()
    local coal = fuel and fuel.get_item_count() or 0
    local nuclear = e.name == "rts-nuclear-plant" -- Phase 5 M3 age3: fuel rods from its network
    el.b_line2.caption = {nuclear and "rts-age3.nuclear-fuel" or "rts.steam-fuel", coal}
    el.b_line2.style.font_color = coal > 0 and COLOR.white or COLOR.red
    el.b_line3.caption = {nuclear and "rts-age3.nuclear-hint" or "rts.steam-hint"}
  elseif rec.kind == "accumulator" then
    local size = e.electric_buffer_size or 0
    el.b_line2.caption = {"rts.accumulator-charge", string.format("%.1f", e.energy / 1e6),
                          string.format("%.1f", size / 1e6)}
    el.b_line3.caption = {"rts.accumulator-hint"}
  elseif rec.kind == "radar" then
    el.b_line2.caption = {"rts.radar-hint"}
  elseif rec.kind == "lab" then
    local cur = research.current(rec.force)
    local state = rec.lab_state
    local starved = state and string.match(state, "^starved: (.+)$")
    el.b_line2.caption = cur and {"rts.lab-researching", tech_name(cur.name), math.floor(cur.progress * 100)}
      or {"rts.lab-idle"}
    if starved then
      el.b_line3.caption = {"rts.lab-starved", "[item=" .. starved .. "]"}
    elseif state == "no network" then
      el.b_line3.caption = {"rts.lab-no-network"}
    else
      el.b_line3.caption = {"rts.lab-hint"}
    end
  elseif rec.kind == "hub" then
    el.b_line2.caption = {"rts.hub-line", supply.HUB_CAP}
    el.b_line3.caption = {"rts.hub-hint"}
  elseif rec.kind == "airfield" or rec.kind == "aa-turret" then -- Phase 5 M3 air: scripts/airgui.lua fills the lines
    local fn = optional_fn("scripts.airgui", {"building_lines"})
    if fn then fn(el, rec) end
  else
    el.b_line2.caption = ""
  end
end

local function update_demolish_button(player, h, un, rec)
  local button = h.el.b_demolish
  -- Phase 5 M1 integration: no Demolish for rolling stock (it would break the train; buildings.demolish_blocked)
  button.visible = rec.kind ~= "train"
  local armed = demolish.is_armed(player.index)
  local blocked = buildings.demolish_blocked(rec)
  set_style(button, armed and "rts_hud_button_armed" or "rts_hud_button")
  button.style.height = P4.DEMOLISH_HEIGHT
  button.caption = armed and {"rts.demolish-confirm"} or {"rts.demolish"}
  button.tooltip = blocked and {"rts.demolish-tooltip-blocked"}
    or {"rts.demolish-tooltip", math.floor(buildings.REFUND_RATIO * 100)}
  button.enabled = not blocked -- Phase 5 M1 integration: greyed like the city panel's (the key still explains)
end

local function require_help_family(name)
  local fn = optional_fn("scripts.help", {"family"})
  return fn ~= nil and fn(name) ~= nil
end

-- Release 0.1.2 (#23, #27): the page of selected own belts, inserters, poles and ghosts. One piece: name, direction
-- or pickup / drop, Rotate and Demolish (Cancel for a ghost); a group: the count per name.
local function update_pieces(player, h, list)
  local el = h.el
  if h.bld_un or el.b_buttons.visible then
    el.b_buttons.clear()
    h.recipe_buttons, h.bld_un = {}, nil
    el.b_buttons.visible = false
    el.b_text.visible = true
    el.b_foot.visible = false
    set_text_width(el, PANEL_INNER)
    if el.b_tabs and el.b_tabs.valid then
      el.b_tabs.clear()
      el.b_tabs.visible = false
    end
  end
  local ghosts, names, order = 0, {}, {}
  for _, e in ipairs(list) do
    if e.type == "entity-ghost" then ghosts = ghosts + 1 end
    local n = pieces.name(e)
    if not names[n] then
      names[n] = 0
      order[#order + 1] = n
    end
    names[n] = names[n] + 1
  end
  table.sort(order)
  el.b_progress.visible = false
  el.b_hp.caption = ""
  el.b_line1.style.font_color = COLOR.white
  el.b_line2.style.font_color = COLOR.white
  el.b_line1.tooltip, el.b_line2.tooltip, el.b_line3.tooltip = "", "", ""
  el.b_line3.caption = ""
  local all_ghosts = ghosts == #list
  if #list == 1 then
    local d = pieces.describe(list[1])
    el.b_name.caption = d.title
    el.b_line1.caption = d.lines[1]
    el.b_line2.caption = d.lines[2]
  else
    el.b_name.caption = {"rts.piece-group-title", #list}
    local parts = {""}
    for i, n in ipairs(order) do
      parts[#parts + 1] = (i > 1 and ", " or "")
      parts[#parts + 1] = {"", names[n] .. " x ", prototypes.entity[n].localised_name}
    end
    el.b_line1.caption = parts
    el.b_line2.caption = ghosts > 0 and {"rts.piece-group-ghosts", ghosts} or ""
  end
  local rotatable = false
  for _, e in ipairs(list) do
    if pieces.describe(e).rotatable then rotatable = true end
  end
  el.b_rotate.visible = rotatable
  if el.b_help and el.b_help.valid then -- 0.1.2 (#30): the help card of a single piece
    local one = #list == 1 and pieces.name(list[1]) or nil
    el.b_help.tags = {rts_help = one or ""}
    el.b_help.visible = one ~= nil and require_help_family(one)
  end
  local armed = demolish.is_armed(player.index)
  el.b_demolish.visible = true
  el.b_demolish.enabled = true
  set_style(el.b_demolish, armed and "rts_hud_button_armed" or "rts_hud_button")
  el.b_demolish.style.height = P4.DEMOLISH_HEIGHT
  if all_ghosts then
    el.b_demolish.caption = {"rts.piece-cancel"}
    el.b_demolish.tooltip = {"rts.piece-cancel-tooltip"}
  else
    el.b_demolish.caption = armed and {"rts.demolish-confirm"} or {"rts.demolish"}
    el.b_demolish.tooltip = {"rts.piece-demolish-tooltip"}
  end
end

local function update_building(player, h, un, rec)
  local el = h.el
  local e = rec.entity
  el.b_rotate.visible = false
  update_demolish_button(player, h, un, rec)
  if h.bld_un ~= un then rebuild_recipe_buttons(player, h, un, rec) end
  el.b_name.caption = {"rts.bld-title", e.localised_name, un}
  if el.b_help and el.b_help.valid then
    el.b_help.tags = {rts_help = e.name}
    el.b_help.visible = require_help_family(e.name)
  end
  local hp, max = e.health or 0, e.max_health or 0
  el.b_hp.caption = max > 0 and {"rts.hp-value", math.floor(hp + 0.5), math.floor(max + 0.5)} or ""
  local ratio = max > 0 and hp / max or 1
  el.b_hp.style.font_color = ratio >= 0.66 and COLOR.green or (ratio >= 0.33 and COLOR.yellow or COLOR.red)
  if rec.kind == "barracks" or P4.crafter(rec.kind) then
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
  local sel_pieces = not rec and optional_fn("scripts.selection", {"get_pieces"})
  local plist = sel_pieces and sel_pieces(player.index) or {}
  if #plist > 0 then
    el.unit_page.visible = false
    el.bld_page.visible = true
    update_pieces(player, h, plist)
    return 0
  end
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
  if not (m and m.phase) or m.phase == "setup" then return {"rts.match-preparing"}, COLOR.yellow end
  if m.phase == "lobby" then return {"rts.match-lobby-help"}, COLOR.yellow end
  local result = result_for(m, own)
  if result == "victory" then return {match.result_text_key(own) or "rts.match-victory"}, COLOR.green end -- Phase 5 M2 diplomacy
  if result == "draw" then return {match.result_text_key(own) or "rts.match-draw"}, COLOR.yellow end -- Phase 5 M2 diplomacy
  if result == "defeat" then return {match.result_text_key(own) or "rts.match-defeat"}, COLOR.red end
  local hs = storage.hud
  if (m.wave or 0) > 0 and hs and hs.wave_tick and game.tick - hs.wave_tick < WAVE_ALERT_TICKS then
    return {"rts.wave-attacking", m.wave}, COLOR.red
  end
  if m.enemy_next_wave then
    return {"rts.wave-next", (m.wave or 0) + 1, clock((m.enemy_next_wave - game.tick) / 60)}, COLOR.yellow
  end
  if m.waves_off then return {"rts.waves-off"}, COLOR.yellow end
  local c = m.config -- Phase 5 M2 diplomacy: a Nation match names its victory mode and time limit
  if c and c.mode == "nation" and c.victory then
    local limit = c.time_limit or 0
    return {"rts.match-goal-nation-" .. c.victory, limit > 0 and clock(limit * 60 - match.elapsed_seconds())
      or {"rts.time-limit-none"}}, COLOR.yellow
  end
  return {"rts.match-goal"}, COLOR.yellow
end

-- Player-specific prompts take the message line over the match messages.
local function player_message(player)
  local is_armed = optional_fn("scripts.orders", {"is_armed"})
  if is_armed and is_armed(player.index) then
    return {"rts.attack-move-armed"}, COLOR.red
  end
  local ghost = cursor.ghost_name(player)
  if ghost and prototypes.item[ghost] then
    return {"rts.placing", prototypes.item[ghost].localised_name}, COLOR.green
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
  el.own.caption = {"rts.army", count_force(own)}
  -- Phase 3 fog: only the enemy units in sight while the match runs, the real total after it. Phase 5 M1 QA round 1:
  -- 0 instead of "?" when none is in sight ("?" read as "unknown" in the middle of fights).
  if m and m.phase == "ended" then
    el.enemy.caption = {"rts.enemies-total", match.enemy_unit_count(own)}
  else
    local seen = match.enemy_units_seen and match.enemy_units_seen(own) or 0
    el.enemy.caption = {"rts.enemies-seen", seen}
  end

  -- Phase 4: supply used / cap, red at the cap, yellow from 90 %
  local sup = supply_of(own)
  el.supply.caption = {"rts.supply", sup.used, sup.cap}
  el.supply.style.font_color = sup.used >= sup.cap and COLOR.red
    or (sup.used >= 0.9 * sup.cap and COLOR.yellow or COLOR.white)
  -- Phase 5 M1: territory share (scripts/territory.lua) and the Cities button, Nation mode only
  local nation = P4.nation() and m.surface ~= nil
  if el.cities and el.cities.valid then
    el.cities.visible = nation
    local share = nation and optional_fn("scripts.territory", {"share"})
    if share then el.cities.caption = {"rts.territory-share", string.format("%.1f", share(own) * 100)} end
  end
  if el.treasury and el.treasury.valid then -- Phase 5 M2 treasury: balance and net per minute, red in deficit
    local strip_fn = nation and optional_fn("scripts.treasury", {"strip"})
    local caption, color, tip
    if strip_fn then caption, color, tip = strip_fn(own) end
    el.treasury.visible = caption ~= nil
    if caption then
      el.treasury.caption, el.treasury.tooltip = caption, tip
      el.treasury.style.font_color = color
    end
  end

  local snap = snapshot(own)
  local res = h.res
  if snap then
    for _, r in ipairs(RESOURCES) do
      if res[r.key] then res[r.key].caption = fmt_count(r.item and (snap.items[r.item] or 0) or snap[r.key]) end
    end
    res.power.caption = {"rts.power-mw", string.format("%.1f", snap.power_demand / 1e6),
                         string.format("%.1f", snap.power_capacity / 1e6)}
    local sat = math.floor(snap.power_satisfaction * 100 + 0.5)
    res.power_sat.caption = string.format("%d%%", sat)
    res.power_sat.style.font_color = sat >= 90 and COLOR.green or (sat >= 50 and COLOR.yellow or COLOR.red)
    res.power.style.font_color = snap.power_demand > 0.9 * snap.power_capacity and COLOR.yellow or COLOR.white
    res.bots.caption = string.format("%d/%d", snap.bots_idle, snap.bots_total)
    -- QA log line, when a value changed and at most every RESOURCE_LOG_TICKS:
    -- "hud resources player=N iron=.. copper=.. steel=.. stone=.. magazines=.. power=../.. MW sat=..% bots=../.."
    local line = string.format("iron=%d copper=%d steel=%d stone=%d magazines=%d power=%.2f/%.2f MW sat=%d%% bots=%d/%d"
      .. " circuits=%d explosives=%d supply=%d/%d",
      snap.iron, snap.copper, snap.steel, snap.stone, snap.magazines, snap.power_demand / 1e6,
      snap.power_capacity / 1e6, sat, snap.bots_idle, snap.bots_total, snap.items["electronic-circuit"] or 0,
      snap.items["rts-explosives"] or 0, sup.used, sup.cap)
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
  -- Phase 3: no build menu in the lobby (the start dialog is up).
  h.build.visible = not prefs(player.index).build_hidden and not (match.in_lobby and match.in_lobby())
  if not h.build.visible then return end
  local snap = snapshot(player.force.name)
  local ghost = cursor.ghost_name(player)
  local nation = P4.nation() -- Phase 5 E1: the Age II tab follows the mode
  if h.build_nation ~= nation then
    h.build_nation = nation
    if h.el.fort_belt and h.el.fort_belt.valid then h.el.fort_belt.visible = nation end -- Phase 5 M3 war2
    for key, button in pairs(h.el.build_tabs or {}) do
      local tab = BUILD_TAB_BY_KEY[key]
      if tab.nation then
        button.visible = nation
      else
        -- room for the Age II icon tab next to three text tabs (Russian captions fill the row)
        button.style.left_padding = nation and P4.TAB_PADDING_NATION or 8
        button.style.right_padding = nation and P4.TAB_PADDING_NATION or 8
      end
    end
    -- Phase 5 M1 integration: the Nation-only items (depot, City charter, fort) of every tab follow the mode at once,
    -- not only after a tab switch (the grid was filled in the lobby under the previous match's mode)
    fill_build_grid(player.index, h)
  end
  for item, button in pairs(h.build_buttons or {}) do
    if button.valid then
      local n = snap and snap.items[item] or 0
      -- Phase 4: an item whose recipe research has not unlocked is greyed out; stock in the network still places.
      local lock = item_lock(player.force, item)
      button.number = n > 0 and n or nil
      button.toggled = ghost == item
      button.enabled = n > 0 or ghost == item or (recipe_for(item) ~= nil and not lock)
      set_style(button, (lock and n == 0) and "rts_hud_build_button_locked" or "rts_hud_build_button")
      button.tooltip = build_tooltip(item, n, lock)
    end
  end
end

---------------------------------------------------------------------------
-- Refresh: alert lines and kill feed (Phase 4)
---------------------------------------------------------------------------
local function alert_style(a)
  return P4.ALERT_TEXT_STYLE[a.text] or P4.ALERT_STYLE[a.kind] or P4.ALERT_DEFAULT_STYLE
end

--- The alert's text as a localised string: {entry.text, params...} (supply.alert / logistics.alert format).
local function alert_text(entry)
  local t
  if type(entry.text) == "string" then
    t = {entry.text}
    for _, param in ipairs(entry.params or {}) do t[#t + 1] = param end
  else
    t = {"rts.alert-generic", tostring(entry.kind)}
  end
  -- Phase 5 M2 world: Nation worlds name the region first ("Iron Hills: hauler lost"; scripts/world.lua place_name)
  local place = entry.position and P4.nation() and P4.place_name and P4.place_name(entry.position)
  if place then return {"rts-world.alert-place", place, t} end
  return t
end

--- Alerts of a force, newest first: every entry younger than `max_age` ticks (all when nil), at most `limit`.
local function force_alerts(force_name, max_age, limit, with_position)
  local out, list = {}, storage.alerts or {}
  for i = #list, 1, -1 do
    local a = list[i]
    if max_age and game.tick - (a.tick or 0) >= max_age then break end
    if a.force == force_name and (not with_position or a.position) then
      out[#out + 1] = a
      if limit and #out >= limit then break end
    end
  end
  return out
end

local function faded(color, age, life, fade)
  local alpha = math.max(0.15, math.min(1, (life - age) / fade))
  return {color[1], color[2], color[3], alpha}
end

local function update_alerts(player, h)
  local own = player.force.name
  local shown = force_alerts(own, P4.ALERT_TICKS, P4.ALERT_SHOWN)
  h.alert_targets = {}
  for i, line in ipairs(h.alert_lines) do
    local a = shown[i]
    line.visible = a ~= nil
    if a then
      local st = alert_style(a)
      local icon = first_sprite(st.icons)
      local age = game.tick - a.tick
      line.caption = {"", icon and ("[img=" .. icon .. "] ") or "", alert_text(a), "   ",
                      {"rts.alert-age", math.floor(age / 60)}}
      line.style.font_color = faded(COLOR[st.color] or COLOR.white, age, P4.ALERT_TICKS, P4.ALERT_FADE_TICKS)
      h.alert_targets[i] = a.position and {x = a.position.x, y = a.position.y} or nil
      line.tooltip = a.position and {"rts.alert-tooltip"} or {"rts.alert-tooltip-no-position"}
    end
  end
  h.alerts.visible = #shown > 0 and not (match.in_lobby and match.in_lobby())
  -- A sound for alerts that just arrived (base attacked, hauler lost); nothing on the first look.
  local pa = util.pstorage(player.index)
  pa.hud_alert = pa.hud_alert or {}
  local seen = pa.hud_alert.seen_tick
  local newest = shown[1] and shown[1].tick or seen
  if seen and newest and newest > seen then
    for _, a in ipairs(shown) do
      if a.tick > seen then
        local sound = alert_style(a).sound
        if sound and helpers.is_valid_sound_path(sound) then
          player.play_sound({path = sound})
          break
        end
      end
    end
  end
  pa.hud_alert.seen_tick = math.max(seen or 0, newest or game.tick)
end

local function side_label(force_name, own)
  if force_name == own then return {"rts.kill-own"} end
  local prefix = match.AI_PREFIX or "rts-ai-" -- plain prefix: "-" is a pattern character
  local n = force_name and string.sub(force_name, 1, #prefix) == prefix
    and tonumber(string.sub(force_name, #prefix + 1))
  if n then return {"rts.force-ai", n} end
  return {"rts.kill-enemy"}
end

local function update_kills(player, h)
  local own = player.force.name
  local list = storage.hud and storage.hud.kills or {}
  local shown = {}
  for i = #list, 1, -1 do
    local k = list[i]
    if game.tick - k.tick >= P4.KILL_TICKS then break end
    if k.seen and k.seen[own] then
      shown[#shown + 1] = k
      if #shown >= P4.KILL_SHOWN then break end
    end
  end
  for i, line in ipairs(h.kill_lines) do
    local k = shown[i]
    line.visible = k ~= nil
    if k then
      local killer = k.killer and valid_sprite("entity/" .. k.killer) and ("[img=entity/" .. k.killer .. "] › ") or ""
      -- Phase 5 M3 QA fix (F2): a building that killed (an AA turret, a turret) is named, not only drawn
      local kp = k.killer and not balance.units[k.killer] and prototypes.entity[k.killer]
      if killer ~= "" and kp then killer = {"", "[img=entity/" .. k.killer .. "] ", kp.localised_name, " › "} end
      line.caption = {"", killer, "[img=" .. unit_sprite(k.name) .. "] ",
                      {"rts.kill-line", unit_name(k.name), side_label(k.force, own)}}
      line.style.font_color = faded(k.force == own and COLOR.red or COLOR.green, game.tick - k.tick, P4.KILL_TICKS,
                                    P4.KILL_FADE_TICKS)
    end
  end
  h.kills.visible = #shown > 0
end

local function update_feeds(player, h)
  update_alerts(player, h)
  update_kills(player, h)
end

local function update(player, h)
  track_match()
  apply_view_settings(player)
  h.panel.visible = not (match.in_lobby and match.in_lobby()) -- Phase 3: no selection panel in the lobby
  update_selection(player, h)
  update_commands(player, h)
  update_groups(player, h)
  update_strip(player, h)
  update_build_menu(player, h)
  update_feeds(player, h)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Destroy the player's HUD frames.
function hud.destroy(player)
  local screen = player.gui.screen
  for _, key in pairs({"panel", "strip", "minimap_frame", "minimap", "build", "alerts", "kills"}) do
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
  build_build_menu(screen, h, player.index)
  build_alerts(screen, h)
  build_kills(screen, h)
  build_minimap(screen, h)
  util.pstorage(player.index).hud = h
  place(player, h)
  update(player, h)
  local res = player.display_resolution
  util.log("hud: built for player %d (display %dx%d, scale %.2f, density %.2f; minimap zoom %.4f, "
    .. "%.2f px/tile at scale 1; build menu %d items)", player.index, res.width, res.height, player.display_scale,
    player.display_density_scale, h.minimap.zoom, h.minimap.zoom * MINIMAP_PX_PER_TILE_AT_ZOOM_1,
    table_size(h.build_buttons))
  return h
end

-- Phase 5: fn(player) after every refresh, e.g. a selection change (scripts/divisiongui.lua: division cards). Load time
-- only. A table field, not a local: the main chunk is close to Lua's 200-local limit.
hud.refresh_hooks = {}
function hud.on_refresh(fn) hud.refresh_hooks[#hud.refresh_hooks + 1] = fn end

--- Update the player's HUD now (selection.lua calls this after every selection change). Builds the HUD
--- when it is missing. Cheap: one pass over the selection and the unit registry, one cached economy snapshot.
function hud.refresh(player_index)
  local player = game.get_player(player_index)
  if not (player and player.connected) then return end
  local h = get_hud(player)
  if not h then
    hud.build(player)
  else
    update(player, h)
  end
  for _, fn in ipairs(hud.refresh_hooks) do fn(player) end
end

-- A torn-down match takes its kill feed, attack-alert rate limits and pings with it (Wave C).
match.on_teardown(function()
  local hs = storage.hud
  if not hs then return end
  for _, ping in ipairs(hs.pings or {}) do
    if ping.tag and ping.tag.valid then ping.tag.destroy() end
  end
  hs.kills, hs.attack_alert, hs.pings = {}, {}, {}
end)

function hud.init()
  storage.hud = storage.hud or {wave_seen = storage.match and storage.match.wave or 0}
  local hs = storage.hud
  hs.attack_alert = hs.attack_alert or {}
  hs.kills = hs.kills or {}
  hs.pings = hs.pings or {}
  -- Every module is loaded by now: confirm the package.loaded lookups the buttons depend on.
  local found = {}
  for _, c in ipairs(COMMANDS) do
    found[#found + 1] = string.format("%s=%s", c.action, optional_fn(c.module, c.fns) and "ok" or "MISSING")
  end
  found[#found + 1] = "is_armed=" .. (optional_fn("scripts.orders", {"is_armed"}) and "ok" or "MISSING")
  found[#found + 1] = "group_recall=" .. (optional_fn("scripts.selection", {"group_recall"}) and "ok" or "MISSING")
  found[#found + 1] = "run_command=" .. (optional_fn("scripts.debug", {"run_command"}) and "ok" or "MISSING")
  util.log("hud: module lookup %s", table.concat(found, " "))
  found = {"techgui.toggle=" .. (optional_fn("scripts.techgui", {"toggle"}) and "ok" or "MISSING"),
           "selection.set=" .. (optional_fn("scripts.selection", {"set"}) and "ok" or "MISSING"),
           "lobby.toggle_menu=" .. (optional_fn("scripts.lobby", {"toggle_menu"}) and "ok" or "MISSING")}
  util.log("hud: module lookup (phase 4) %s", table.concat(found, " "))
  -- QA log line: "hud: build menu tab <key>: <item><-<recipe>[ locked by <tech>] ..." per tab
  local force = game.forces[PLAYER]
  for _, tab in ipairs(BUILD_TABS) do
    local items = {}
    for _, item in ipairs(build_items(tab)) do
      local r = recipe_for(item)
      local lock = force and item_lock(force, item)
      items[#items + 1] = string.format("%s<-%s%s", item, r and r.name or "none",
        lock and (" locked by " .. tostring(lock)) or "")
    end
    util.log("hud: build menu tab %s: %s", tab.key, table.concat(items, " "))
  end
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
  -- Stop and Hold run every handler of their key (`input`): orders.lua for units, commander.lua for the Commander (a
  -- spider-vehicle, which orders.lua cannot command), abilities.lua's disarm, and any module that hooks the key later.
  -- The button therefore does exactly what X / H do.
  local handler = c.input and script.get_event_handler(c.input)
  if handler then
    local count = optional_fn("scripts.selection", {"count"})
    local n = count and count(player.index) or -1
    local proto = prototypes.custom_input[c.input]
    handler({name = proto and proto.event_id, input_name = c.input, player_index = player.index, tick = game.tick,
             cursor_position = player.position, cursor_display_location = {x = 0, y = 0}})
    -- QA log line: "hud click stop|hold player=N result=<selected> (rts-stop handlers)"
    util.log("hud click %s player=%d result=%d (%s handlers)", action, player.index, n, c.input)
    return n
  end
  local fn = optional_fn(c.module, c.fns)
  if not fn then
    local wanted = c.module .. "." .. table.concat(c.fns, "/")
    player.print({"rts.not-available", {c.caption}, wanted})
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
    player.print({"rts.group-recall-hint", n})
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

--- Recipe button of the building panel. Pause ("") clears the recipe; Auto toggles Auto; the Endless button toggles
--- the player's endless mode; a recipe button orders crafts like vanilla handcrafting (Release 0.1.2, #22): click = 1,
--- Shift = 5, Ctrl = as many as the network can pay, right click = take 1 / 5 / all off the order. With Endless on a
--- recipe click is endless production (production.set_recipe), as before 0.1.2. `mods` = {shift, control, right,
--- endless = true for this call only}.
--- QA log lines: "recipe set <kind>#<unit> <recipe|none> ok=true|false now=<recipe|none> player=N" (endless / pause),
--- "recipe queue <kind>#<unit> <recipe> +<n> ok=... player=N", "recipe unqueue <kind>#<unit> -<n> left=<n> player=N".
function hud.recipe_click(player, recipe, mods)
  local un, rec = selected_building(player)
  if not rec then return false end
  mods = mods or {}
  if recipe == P4.AUTO then -- Phase 5 E1: toggle Auto
    local on = not production.is_auto(rec)
    local done = production.set_auto(un, on)
    util.log("recipe auto %s#%d %s ok=%s player=%d", rec.kind, un, on and "on" or "off", tostring(done),
      player.index)
    return done
  end
  if recipe == P4.ENDLESS then
    local p = prefs(player.index)
    p.endless = not p.endless or nil
    util.log("recipe endless %s player=%d", p.endless and "on" or "off", player.index)
    return true
  end
  local name = (recipe ~= nil and recipe ~= "") and recipe or nil
  if name and mods.right then -- take crafts off the order
    local n = mods.control and rec.queue and rec.queue.remaining or (mods.shift and 5 or 1)
    local left = production.unqueue(un, n)
    util.log("recipe unqueue %s#%d -%d left=%s player=%d", rec.kind, un, n, tostring(left), player.index)
    return left ~= nil
  end
  if name and not (mods.endless or prefs(player.index).endless) then
    local n = mods.control and production.affordable(un, name) or (mods.shift and 5 or 1)
    local ok = production.queue_recipe(un, name, n)
    util.log("recipe queue %s#%d %s +%d ok=%s player=%d", rec.kind, un, name, n, tostring(ok), player.index)
    return ok
  end
  local ok = production.set_recipe(un, name)
  local now = rec.entity.valid and rec.entity.get_recipe()
  util.log("recipe set %s#%d %s ok=%s now=%s player=%d", rec.kind, un, name or "none", tostring(ok),
    now and now.name or "none", player.index)
  return ok
end

--- Build menu tab: "economy", "production" or "defence". QA log line: "hud build tab <key> player=N: <items>".
function hud.set_build_tab(player, key)
  local tab = BUILD_TAB_BY_KEY[key]
  if not tab then return false end
  prefs(player.index).build_tab = key
  local h = get_hud(player)
  if h then
    fill_build_grid(player.index, h)
    update_build_menu(player, h)
  end
  util.log("hud build tab %s player=%d: %s", key, player.index, table.concat(build_items(tab), " "))
  return true
end

--- Unit card: keep only the units of that prototype in the selection (Shift: drop them instead).
--- QA log line: "hud click card <unit> player=N shift=true|false -> selected=N".
function hud.card_click(player, name, shift)
  local set_fn = optional_fn("scripts.selection", {"set"})
  local p = pstate(player.index)
  if not (set_fn and p and p.selection) then return 0 end
  local keep = {}
  for un in pairs(p.selection) do
    local rec = live_record(un)
    if rec and ((rec.entity.name == name) ~= (shift == true)) then keep[#keep + 1] = rec.entity end
  end
  local n = set_fn(player.index, keep)
  util.log("hud click card %s player=%d shift=%s -> selected=%d", name, player.index, tostring(shift == true), n)
  return n
end

--- Research [T] button: the research panel (scripts/techgui.lua).
function hud.toggle_research(player)
  local toggle = optional_fn("scripts.techgui", {"toggle"})
  util.log("hud click research player=%d%s", player.index, toggle and "" or " (techgui.toggle missing)")
  if toggle then toggle(player) end
end

--- "How to play" (F11, the ? button): 10 lines in a centred frame; Escape or the close button closes it.
--- QA log lines: "hud help opened|closed player=N (<source>)".
function hud.toggle_help(player, source)
  local screen = player.gui.screen
  local frame = screen[HELP_FRAME]
  if frame then
    frame.destroy()
    util.log("hud help closed player=%d (%s)", player.index, source or "?")
    return false
  end
  frame = screen.add({type = "frame", name = HELP_FRAME, direction = "vertical"})
  frame.auto_center = true
  frame.style.width = P4.HELP_WIDTH
  local bar = frame.add({type = "flow", direction = "horizontal"})
  bar.drag_target = frame
  bar.add({type = "label", caption = {"rts.help-title"}, style = "frame_title", ignored_by_interaction = true})
  local drag = bar.add({type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.style.right_margin = 4
  bar.add({type = "sprite-button", name = PREFIX .. "help_close", style = "frame_action_button",
           sprite = "utility/close", tooltip = {"rts.help-close-tooltip"}, tags = {rts_hud = "help"}})
  local inner = frame.add({type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding"})
  -- Phase 5 M3 integration: the Nation page outgrew 1280x800 in Russian; it scrolls inside 80 % of the window height
  local res, scale = player.display_resolution, player.display_scale
  local pane = inner.add({type = "scroll-pane", direction = "vertical", horizontal_scroll_policy = "never",
                          vertical_scroll_policy = "auto"})
  pane.style.maximal_height = math.max(300, math.floor(res.height / scale * 0.8) - 60)
  inner = pane.add({type = "flow", direction = "vertical"}) -- a frame style has no vertical_spacing
  inner.style.vertical_spacing = 6
  -- Phase 5 M2 integration: a Nation match (or the lobby with Mode = Nation) gets the Nation page with every hotkey
  local lobby_mode = storage.lobby and storage.lobby.pending and storage.lobby.pending.mode
  local m = storage.match
  local running = m and m.phase == "running"
  local nation = (running and P4.nation()) or (not running and lobby_mode == "nation")
  local keys = {}
  if nation then
    for _, k in ipairs(P4.HELP_NATION) do keys[#keys + 1] = k end
  else
    for i = 1, P4.HELP_LINES do keys[#keys + 1] = "rts.help-" .. i end
  end
  for _, key in ipairs(keys) do
    local line = inner.add({type = "label", caption = {key}})
    line.style.single_line = false
    line.style.maximal_width = P4.HELP_WIDTH - 60 -- Phase 5 M3 integration: room for the scroll bar
  end
  player.opened = frame
  util.log("hud help opened player=%d (%s): %d lines%s", player.index, source or "?", #keys, nation and " (nation)" or "")
  return true
end

local function jump_to_alert(player, a, source, i, n)
  camera.jump_to(player, a.position)
  util.log("hud alert jump player=%d source=%s kind=%s at %s age=%.1fs (%d of %d)", player.index, source,
    tostring(a.kind), util.pos_str(a.position), (game.tick - a.tick) / 60, i, n)
end

--- F3: the camera goes to the newest alert of the player's force that has a position; pressing again within
--- P4.ALERT_JUMP_CYCLE_TICKS goes to the next older one (cycling). Returns the alert or nil.
function hud.alert_hotkey(player)
  local list = force_alerts(player.force.name, nil, 20, true)
  local pa = util.pstorage(player.index)
  pa.hud_alert = pa.hud_alert or {}
  local st = pa.hud_alert
  if #list == 0 then
    util.log("hud alert jump player=%d source=F3: no alert with a position", player.index)
    return nil
  end
  local i = 1
  if st.jump_tick and game.tick - st.jump_tick < P4.ALERT_JUMP_CYCLE_TICKS then
    i = (st.jump_index or 0) % #list + 1
  end
  st.jump_tick, st.jump_index = game.tick, i
  jump_to_alert(player, list[i], "F3", i, #list)
  return list[i]
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
    hud.recipe_click(player, element.tags.recipe, {shift = e.shift, control = e.control,
      right = e.button == defines.mouse_button_type.right})
  elseif action == "menu" then
    local toggle = optional_fn("scripts.lobby", {"toggle_menu"})
    util.log("hud click menu player=%d%s", player.index, toggle and "" or " (lobby.toggle_menu missing)")
    if toggle then toggle(player) end
  elseif action == "build_tab" then
    hud.set_build_tab(player, element.tags.tab)
  elseif action == "factory_tab" then -- Phase 5 E1: the factory page's category tabs
    prefs(player.index).factory_tab = element.tags.tab
    h.bld_un = nil -- rebuild the recipe grid on the refresh below
    util.log("hud factory tab %s player=%d", tostring(element.tags.tab), player.index)
  elseif action == "card" then
    hud.card_click(player, element.tags.unit, e.shift)
  elseif action == "research" then
    hud.toggle_research(player)
  elseif action == "cities" then -- Phase 5 M1: city list (scripts/citygui.lua)
    local toggle = optional_fn("scripts.citygui", {"toggle_list"})
    if toggle then toggle(player) end
  elseif action == "market" then -- Phase 5 M2 treasury: market panel (scripts/marketgui.lua, M)
    local toggle = optional_fn("scripts.marketgui", {"toggle"})
    if toggle then toggle(player) end
  elseif action == "help" then
    hud.toggle_help(player, element.name == PREFIX .. "help_close" and "close button" or "? button")
  elseif action == "fort_belt" then -- Phase 5 M3 war2: the fort belt tool (scripts/belts.lua)
    local toggle = optional_fn("scripts.belts", {"toggle_tool"})
    if toggle then toggle(player) end
  elseif action == "demolish" then
    demolish.click(player)
  elseif action == "rotate_piece" then -- Release 0.1.2: rotate the selected pieces / ghosts
    local rotated = 0
    local get = optional_fn("scripts.selection", {"get_pieces"})
    for _, ent in ipairs(get and get(player.index) or {}) do
      local ok = pcall(function() return ent.rotate({by_player = player}) end)
      if ok then rotated = rotated + 1 end
    end
    util.log("hud click rotate pieces player=%d n=%d", player.index, rotated)
  elseif action == "disband" then -- Phase 5 M2 integration: Disband the selected units (Nation mode)
    local result, n = demolish.disband(player.index)
    util.log("disband: click player=%d result=%s n=%d", player.index, result, n)
  elseif action == "alert" then
    local target = h.alert_targets and h.alert_targets[element.tags.line]
    if target then
      camera.jump_to(player, target)
      util.log("hud alert jump player=%d source=click line=%d at %s", player.index, element.tags.line,
        util.pos_str(target))
    end
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
  -- Phase 5 M3 war2: B with an own train selected is its Bombard stance (scripts/trainswar.lua, P4.KEYS below)
  local claims_b = optional_fn("scripts.trainswar", {"claims_b"})
  if claims_b and claims_b(e.player_index) then return end
  local pr = prefs(e.player_index)
  pr.build_hidden = not pr.build_hidden
  util.log("hud build menu %s player=%d (B)", pr.build_hidden and "hidden" or "shown", e.player_index)
  hud.refresh(e.player_index)
end)

-- Phase 4: F3 jumps to the newest alert (again: the next older one), F11 toggles "How to play".
-- Phase 5 M2 (docs/PHASE5-M2.md §5): panel hotkeys. Each M2 panel adds one entry {input, key, module, fn}: the custom
-- input (prototypes/inputs.lua) calls module.fn(player), looked up at call time like the strip buttons.
P4.KEYS = {
  {input = "rts-diplomacy", key = "F4", module = "scripts.diplomacygui", fn = "toggle"}, -- Phase 5 M2 diplomacy
  {input = "rts-market", key = "M", module = "scripts.marketgui", fn = "toggle"}, -- Phase 5 M2 treasury
  {input = "rts-minimap-mode", key = "N", module = "scripts.strategic", fn = "toggle_minimap"}, -- Phase 5 M2 world
  {input = "rts-airfield-panel", key = "Y", module = "scripts.airgui", fn = "toggle"}, -- Phase 5 M3 air
  -- Phase 5 M3 war2: keys that share an input with an older meaning; the module decides (it gets the event too):
  -- F with no unit selected = fort belt tool, B with a train selected = Bombard, H at a front = hold the line
  {input = "rts-attack-move", key = "F", module = "scripts.belts", fn = "key_f"},
  {input = "rts-build-menu", key = "B", module = "scripts.trainswar", fn = "key_b"},
  {input = "rts-hold", key = "H", module = "scripts.fronts", fn = "key_h"},
}
for _, k in ipairs(P4.KEYS) do
  events.on(k.input, function(e)
    local player = game.get_player(e.player_index)
    local fn = player and optional_fn(k.module, {k.fn})
    util.log("hud: hotkey %s (%s) player=%d%s", k.input, k.key, e.player_index, fn and "" or " (module missing)")
    if fn then fn(player, e) end -- Phase 5 M3 war2: the event too (cursor position)
  end)
end

events.on("rts-alert-jump", function(e)
  local player = game.get_player(e.player_index)
  if player then hud.alert_hotkey(player) end
end)

events.on("rts-help", function(e)
  local player = game.get_player(e.player_index)
  if player then hud.toggle_help(player, "F11") end
end)

events.on(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and el.name == HELP_FRAME then
    el.destroy()
    util.log("hud help closed player=%d (Escape)", e.player_index)
  end
end)

-- Phase 4 alert "base-attacked": an own registered building took damage from another force. At most one per force
-- every P4.ATTACK_ALERT_PERIOD ticks, only for forces with players (and rts-player, for the headless autotest).
-- The on_entity_damaged filter is the shared one that scripts/research.lua sets (every RTS building name plus the
-- armored units); this handler only adds itself to the bus and returns at once for anything but a building.
events.on(defines.events.on_entity_damaged, function(e)
  local entity = e.entity
  if not (entity and entity.valid and buildings.KIND_BY_NAME[entity.name]) then return end
  local hs = storage.hud
  local by = e.force
  if not (hs and hs.attack_alert and by) then return end
  local force = entity.force
  local f = force.name
  if by.name == f then return end
  local last = hs.attack_alert[f]
  if last and game.tick - last < P4.ATTACK_ALERT_PERIOD then return end
  if f ~= PLAYER and #force.players == 0 then return end
  hs.attack_alert[f] = game.tick
  supply.alert(f, "base-attacked", "rts.alert-base-attacked", {"[entity=" .. entity.name .. "]", entity.localised_name},
    entity.position)
  local cause = e.cause
  util.log("hud: alert base-attacked for %s: %s #%s at %s, %.0f damage by %s%s", f, entity.name,
    tostring(entity.unit_number), util.pos_str(entity.position), e.final_damage_amount, by.name,
    (cause and cause.valid) and (" (" .. cause.name .. ")") or "")
end)

-- Kill feed: every death of an RTS unit (balance.units: walkers, heavies, drones, raiders, artillery, mk2 units,
-- haulers, commanders). seen[force] = the victim or the killer is of that force, or that force has an entity within
-- KILL_SIGHT tiles of it (Phase 5 M3 perf: was the chunk's chart visibility).
local KILL_SIGHT = 40
events.on(defines.events.on_entity_died, function(e)
  local entity = e.entity
  if not (entity and entity.valid and balance.units[entity.name]) then return end
  local hs = storage.hud
  if not (hs and hs.kills) then return end
  local f = entity.force.name
  local cause = e.cause
  local killer = (cause and cause.valid) and cause.name or nil
  local killer_force = e.force and e.force.name or ((cause and cause.valid) and cause.force.name or nil)
  local pos, surface = entity.position, entity.surface
  local seen = {}
  for _, player in pairs(game.connected_players) do
    local pf = player.force
    if seen[pf.name] == nil then
      -- Phase 5 M3 perf (determinism): sight, not chart state: a headless server charts nothing, a GUI peer does, so
      -- is_chunk_visible gave the server and the clients different kill lists (storage) and kill-feed GUIs
      seen[pf.name] = pf.name == f or pf.name == killer_force
        or surface.count_entities_filtered({position = pos, radius = KILL_SIGHT, force = pf, limit = 1}) > 0
    end
  end
  local list = hs.kills
  list[#list + 1] = {tick = game.tick, name = entity.name, force = f, killer = killer, killer_force = killer_force,
                     seen = seen}
  while #list > P4.KILL_KEEP do table.remove(list, 1) end
end)

-- Minimap pings: a chart tag for 10 s at every new alert of P4.PING_KINDS (base attacked, hauler lost) that has a
-- position, for forces with players. The HUD minimap and the map view draw chart tags.
local ping_signal
local function update_pings()
  local hs = storage.hud
  if not hs then return end
  hs.pings = hs.pings or {}
  for i = #hs.pings, 1, -1 do
    local ping = hs.pings[i]
    if game.tick - ping.tick >= P4.PING_TICKS or not (ping.tag and ping.tag.valid) then
      if ping.tag and ping.tag.valid then ping.tag.destroy() end
      table.remove(hs.pings, i)
    end
  end
  local list = storage.alerts or {}
  local last = hs.ping_tick or game.tick -- first look: older alerts get no ping
  local newest = last
  for i = #list, 1, -1 do
    local a = list[i]
    if (a.tick or 0) <= last then break end
    newest = math.max(newest, a.tick)
    local force = game.forces[a.force]
    if P4.PING_KINDS[a.kind] and a.position and force and #force.players > 0 then
      if ping_signal == nil then
        ping_signal = false
        for _, name in ipairs(P4.PING_SIGNALS) do
          if prototypes.virtual_signal[name] then ping_signal = name break end
        end
      end
      local surface = (match.surface and match.surface()) or util.surface()
      local ok, tag = pcall(force.add_chart_tag, surface, {position = a.position,
        icon = ping_signal and {type = "virtual", name = ping_signal} or nil, text = ping_signal and "" or "!"})
      if ok and tag then
        hs.pings[#hs.pings + 1] = {tag = tag, tick = game.tick}
        util.log("hud: minimap ping %s for %s at %s", a.kind, a.force, util.pos_str(a.position))
      end
    end
  end
  hs.ping_tick = newest
end

-- Alert lines and the kill feed fade, so they refresh every P4.FEED_PERIOD ticks (the full refresh covers its
-- own ticks).
events.on_nth_tick(P4.FEED_PERIOD, function(e)
  update_pings()
  if e.tick % REFRESH_PERIOD == 0 then return end
  for _, player in pairs(game.connected_players) do
    local h = get_hud(player)
    if h then update_feeds(player, h) end
  end
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
do -- dev-only locals stay out of the main chunk (Lua allows 200 locals there)
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
    util.log("hud: selftest click on the CC at %s -> selected building #%s",
      cc and util.pos_str(cc.entity.position) or "-",
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
    hud.recipe_click(player, "rts-walker-kit", {endless = true})
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
      hud.recipe_click(player, "rts-extractor", {endless = true})
      hud.refresh(player.index)
      util.log("hud: selftest factory #%d selected=%s", un, tostring(selected_building(player) == un))
      screenshot(player)
      return
    end
    util.log("hud: selftest no own factory (robots have not built the ghost)")
  end)
  -- Phase 4 steps, between the match-flow menu (1320) and the AI kill (1500); docs/qa/phase2-hud-notes.md "Phase 4".
  do -- scoped: the main chunk is close to the 200-local limit
    local P4_UNITS = {{"rts-drone", 3}, {"rts-raider", 2}, {"rts-artillery", 1}, {"rts-walker-mk2", 2}}
    local function first_ai(player)
      for _, f in ipairs(match.ai_forces and match.ai_forces() or {}) do
        if f ~= player.force.name then return f end
      end
      return ENEMY
    end

    -- The qa-reset at 930 starts a new match, so the barracks and factory of the Phase 2 steps are gone: place them.
    local function ensure_building(player, kind, name, offset, surface)
      for un, rec in buildings.for_force(player.force.name, kind) do return un, rec end
      local home = match.home(player.force.name)
      local pos = surface.find_non_colliding_position(name, {x = home.x + offset.x, y = home.y + offset.y}, 20, 1)
      local e = pos and surface.create_entity({name = name, position = pos, force = player.force, raise_built = true})
      local rec = e and buildings.register(e)
      return e and e.unit_number, rec
    end

    camera.add_selftest_step(1350, "hud_p4_setup", function(player)
      local own = player.force.name
      local home = match.home(own)
      local surface = (match.surface and match.surface()) or player.surface
      camera.home(player)
      local spawned, list = {}, {}
      for i, spec in ipairs(P4_UNITS) do
        for j = 1, spec[2] do
          local pos = {x = home.x + 8 + 3 * j, y = home.y + 10 + 4 * i}
          local e = prototypes.entity[spec[1]] and units.spawn(spec[1], pos, own, nil, surface)
          if e then
            list[#list + 1] = e
            if j == 1 then e.health = e.max_health * 0.45 end -- the HP bars show yellow
          end
        end
        spawned[#spawned + 1] = spec[1]
      end
      ensure_building(player, "barracks", "rts-barracks", {x = -14, y = -10}, surface)
      ensure_building(player, "factory", "rts-factory", {x = -14, y = 10}, surface)
      local hauler = logistics.spawn_hauler(surface, {x = home.x + 26, y = home.y + 14}, own)
      if hauler then list[#list + 1] = hauler end
      local spawn_commander = optional_fn("scripts.commander", {"spawn_now"}) -- the abilities agent's module
      local hero = spawn_commander and spawn_commander(own)
      if hero then list[#list + 1] = hero end
      -- kill feed: one own drone killed by the first AI
      local ai = first_ai(player)
      for _, e in ipairs(list) do
        if e.valid and e.name == "rts-drone" then
          e.die(ai)
          break
        end
      end
      local alive = {}
      for _, e in ipairs(list) do
        if e.valid then alive[#alive + 1] = e end
      end
      local set_fn = optional_fn("scripts.selection", {"set"})
      local n = set_fn and set_fn(player.index, alive) or 0
      -- base-attacked: a stockpile damaged by the AI (the rate limit is cleared first, this is a test)
      storage.hud.attack_alert[own] = nil
      for _, rec in buildings.for_force(own, "stockpile") do
        rec.entity.damage(40, ai, "physical")
        break
      end
      -- unit-locked: the barracks makes raider kits (locked for players until Raiders is researched) and one is ready
      local un, rec = own_barracks(player)
      local kit_ok = false
      if rec then
        production.set_recipe(un, "rts-raider-kit")
        local out = rec.entity.get_inventory(defines.inventory.crafter_output) -- 2.1: assembling_machine_output -> crafter_output
        kit_ok = out and out.insert({name = "rts-raider-kit", count = 1}) == 1
      end
      hud.set_build_tab(player, "defence")
      hud.refresh(player.index)
      util.log("hud: selftest p4 setup: spawned %s, hauler=%s, commander=%s, selected=%d, raider kit in barracks #%s: "
        .. "%s, supply %d/%d", table.concat(spawned, " "), tostring(hauler ~= nil), tostring(hero ~= nil), n,
        tostring(un),
        tostring(kit_ok),
        supply_of(own).used, supply_of(own).cap)
    end)
    -- The Stop button runs the X handlers: orders.lua for the units, commander.lua for the selected Commander.
    camera.add_selftest_step(1365, "hud_p4_stop_button", function(player) run_command(player, "stop") end)
    camera.add_selftest_step(1380, "hud_p4_screenshot_units", screenshot)
    camera.add_selftest_step(1395, "hud_p4_card_click", function(player)
      hud.card_click(player, "rts-raider", true)  -- every unit but the raiders
      hud.card_click(player, "rts-drone", false)  -- only the drones
    end)
    camera.add_selftest_step(1410, "hud_p4_select_barracks", function(player)
      local handle_area = optional_fn("scripts.selection", {"handle_area"})
      local un, rec = own_barracks(player)
      if not (rec and handle_area) then
        util.log("hud: selftest p4 no own barracks")
        return
      end
      handle_area(player.index, {}, zero_area(rec.entity.position), false, player.surface)
      hud.set_build_tab(player, "production")
      hud.refresh(player.index)
      local b = research.block_of(un)
      util.log("hud: selftest p4 barracks #%d selected=%s block=%s %s", un, tostring(selected_building(player) == un),
        b and b.reason or "none", b and tostring(b.tech or b.unit) or "")
      screenshot(player)
    end)
    camera.add_selftest_step(1440, "hud_p4_factory", function(player)
      local handle_area = optional_fn("scripts.selection", {"handle_area"})
      hud.set_build_tab(player, "economy")
      for un, rec in buildings.for_force(player.force.name, "factory") do
        if handle_area then handle_area(player.index, {}, zero_area(rec.entity.position), false, player.surface) end
        hud.recipe_click(player, "rts-laser-turret", {endless = true}) -- refused: locked
        hud.refresh(player.index)
        local h = get_hud(player)
        local locked = {}
        for name, lock in pairs(h and h.recipe_locks or {}) do
          if lock then locked[#locked + 1] = name .. "=" .. tostring(lock) end
        end
        table.sort(locked)
        util.log("hud: selftest p4 factory #%d selected=%s, %d recipe buttons, locked: %s", un,
          tostring(selected_building(player) == un), table_size(h and h.recipe_buttons or {}),
          table.concat(locked, " "))
        break
      end
      local a = hud.alert_hotkey(player)
      util.log("hud: selftest p4 F3 -> %s", a and (a.kind .. " " .. util.pos_str(a.position)) or "none")
      screenshot(player)
    end)
    camera.add_selftest_step(1470, "hud_p4_help", function(player)
      hud.toggle_help(player, "selftest")
      screenshot(player)
    end)
    camera.add_selftest_step(1500, "hud_p4_done", function(player)
      if player.gui.screen[HELP_FRAME] then hud.toggle_help(player, "selftest") end
      local list = {}
      for _, a in ipairs(force_alerts(player.force.name, nil, 10)) do list[#list + 1] = a.kind end
      util.log("RTS_P4_HUD_DONE player %d: alerts (newest first) %s; kills %d", player.index, table.concat(list, " "),
        #(storage.hud.kills or {}))
    end)
  end

  camera.add_selftest_step(3000, "hud_done", function(player) -- about 5 s into the first enemy wave
    screenshot(player)
    util.log("RTS_HUD_DONE player %d", player.index)
  end)
end

hud.P4 = P4 -- Phase 5 M3 age3: modules add Nation-only items, alert styles and recipe tabs at load time

return hud
