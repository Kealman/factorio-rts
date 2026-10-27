-- Phase 5 M1 city GUI (docs/PHASE5-M1.md "cities.lua / citygui.lua"): Nation mode only.
--
-- City panel: one frame in player.gui.screen, left of the hub panel (scripts/hubgui.lua shows the stockpile policy of
-- the same City Center or CC on the right edge). It opens while an own City Center or the capital CC is the selected
-- building, or from the city list (pinned until closed). Content: name and tier, a rename field, land (radius, cells,
-- share of the nation's land), supply, the next tier's requirements (buildings on its land, goods delivered to its
-- market), the logistic networks on its land, and the make targets (one row per item: icon, target field, remove;
-- an add button opens the scripted item picker, scripts/itempicker.lua, left of the panel: QA round 1 replaced the
-- choose-elem-button, which took the rts-cursor from the player's cursor). Fields write cities.rename /
-- cities.set_make_target; a click on a number field selects its text, so typing replaces the value.
--
-- City list: a small frame in the top-left corner under the kill feed, one row per own city: a jump button (name, the
-- camera goes there), tier and land cells, an "open panel" button. hud.lua's strip has the territory share and a
-- "Cities" button that shows or hides it (citygui.toggle_list).
--
-- Polling every POLL_PERIOD ticks, values every REFRESH_PERIOD. Owns storage.players[i].citygui = {frame, el, city,
-- key, pinned, closed, list = frame, list_rows, list_key, list_hidden, name_req, default_name}. Element names start
-- with "rts_citygui_".
-- Texts: [rts] keys "citygui-*" (locale/*/cities.cfg).
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local camera = require("scripts.camera")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local demolish = require("scripts.demolish") -- Phase 5 M1 integration: the panel's Demolish button
local hubgui = require("scripts.hubgui") -- Phase 5 M1 integration: its title follows a rename
local itempicker = require("scripts.itempicker") -- QA round 1: the make-target picker
local match = require("scripts.match") -- Phase 5 M2 integration: the capturing nation's name
local CAPTURE_TICKS = require("balance").nation.war.capture.ticks -- Phase 5 M2 integration

local citygui = {}
citygui.foot_hook, citygui.refresh_hook = nil, nil -- Phase 5 M3 age3: fn(foot, el, c), fn(player, el, c) (sinks.lua)

local FRAME, LIST = "rts_citygui_frame", "rts_citygui_list"
local PREFIX = "rts_citygui_"
local WIDTH = 300
local LIST_WIDTH = 300   -- Phase 5 M2 integration: 260 cut Russian names and pushed the magnifier out with the attack mark
local MARGIN = 8
local TOP = 8 + 228 + 8        -- as the hub panel: below the HUD minimap
local HUB_WIDTH = 340          -- hubgui.lua WIDTH: the city panel sits left of it
local LIST_TOP = 8 + 120       -- under the kill feed (5 lines)
local POLL_PERIOD = 10
local REFRESH_PERIOD = 30
local FIELD_WIDTH = 72
local COLOR = {white = {1, 1, 1}, dim = {0.72, 0.72, 0.72}, yellow = {1, 0.85, 0.3}, green = {0.5, 1, 0.5}, red = {1, 0.42, 0.36}}
-- Phase 5 M2 people: the panel's people section (residents and housing, growth, happiness and power, one bar per need,
-- workforce / jobs / free / recruits, the draft drop-down, the nation's labor priorities with up / down buttons) and
-- the staffing box over the HUD's building page for a selected staffed building (staff %, workers, city, family, Pin).
-- scripts/population.lua and scripts/labor.lua load after this module and set cities.people / cities.labor.
local PB = require("balance").nation.people
local netwait = require("scripts.netwaitline") -- 0.1.2 (#26)
local STAFF = "rts_citygui_staff"
local STAFF_WIDTH = 420
local HUD_PANEL_HEIGHT = 126   -- hud.lua PANEL_HEIGHT: the staffing box sits right above the building page
COLOR.red = {1, 0.45, 0.4}
local function people() return cities.people, cities.labor end

local function pstate(player_index)
  local p = util.pstorage(player_index)
  p.citygui = p.citygui or {}
  return p.citygui
end

local function nation_running()
  local m = storage.match
  return territory.nation() and m.phase ~= "lobby"
end

local function tier_name(tier) return {cities.TIER_KEYS[tier] or "rts.city-tier-1"} end

---------------------------------------------------------------------------
-- City panel
---------------------------------------------------------------------------
-- The city of the selected building (own City Center or CC), or nil.
local function selected_city(player)
  local un, rec = selection.get_building(player.index)
  if not rec or rec.force ~= player.force.name then return nil end
  local c = cities.of_center(un)
  return c
end

local function destroy_panel(g, player)
  if g.frame and g.frame.valid then g.frame.destroy() end
  g.frame, g.el, g.city, g.key, g.targets = nil, nil, nil, nil, nil
  if player then itempicker.close(player, "citygui") end
end

local function place_panel(player, frame)
  local s, res = player.display_scale, player.display_resolution
  local x = res.width - math.floor((HUB_WIDTH + MARGIN + WIDTH + MARGIN) * s + 0.5)
  frame.location = {math.max(0, x), math.floor(TOP * s + 0.5)}
end

local function label(parent, style, caption, width)
  local l = parent.add({type = "label", style = style or "rts_hud_label", caption = caption or ""})
  l.style.maximal_width = width or (WIDTH - 20)
  l.style.single_line = false
  return l
end

local function add_target_row(g, item, n)
  local tbl = g.el.targets
  local proto = prototypes.item[item]
  if not (tbl and tbl.valid and proto) or g.targets[item] then return end
  tbl.add({type = "sprite", sprite = "item/" .. item, tooltip = proto.localised_name})
  local tf = tbl.add({type = "textfield", name = PREFIX .. "target_" .. item, text = n and tostring(n) or "",
    numeric = true, allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true,
    style = "short_number_textfield", tooltip = {"rts.citygui-target-tooltip"},
    tags = {rts_citygui = "target", city = g.city, item = item}})
  tf.style.width = FIELD_WIDTH
  tbl.add({type = "sprite-button", name = PREFIX .. "remove_" .. item, sprite = "utility/close",
    style = "frame_action_button", tooltip = {"rts.citygui-target-remove"},
    tags = {rts_citygui = "remove", city = g.city, item = item}})
  g.targets[item] = tf
end

-- Phase 5 M2 people ---------------------------------------------------------------------------------------------
local function build_people(frame, el, c)
  local pop = people()
  if not pop then return end
  label(frame, "rts_hud_heading_label", {"rts-people.citygui-people"})
  el.p_pop = label(frame, "rts_hud_label")
  el.p_mood = label(frame, "rts_hud_label")
  local needs = frame.add({type = "table", column_count = 3})
  needs.style.horizontal_spacing = 6
  needs.style.vertical_spacing = 2
  el.p_bars = {}
  for _, spec in ipairs(PB.needs) do
    local icon = needs.add({type = "sprite", sprite = "item/" .. spec.item, tooltip = {"item-name." .. spec.item}})
    local bar = needs.add({type = "progressbar", style = "rts_hud_progressbar", value = 0,
                           tooltip = {"rts-people.citygui-need-tooltip", {"item-name." .. spec.item}, spec.per}})
    bar.style.width = 110
    local text = needs.add({type = "label", style = "rts_hud_dim_label", caption = ""})
    el.p_bars[spec.item] = {icon = icon, bar = bar, text = text}
  end
  el.p_work = label(frame, "rts_hud_label")
  el.p_work.tooltip = {"rts-people.citygui-work-tooltip"}
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  row.add({type = "label", style = "rts_hud_label", caption = {"rts-people.citygui-draft"},
           tooltip = {"rts-people.citygui-draft-tooltip"}})
  local items = {}
  for i, v in ipairs(PB.draft.levels) do items[i] = {"rts-people.citygui-draft-level", math.floor(v * 100 + 0.5)} end
  el.p_draft = row.add({type = "drop-down", name = PREFIX .. "draft", items = items, selected_index = 1,
                        tooltip = {"rts-people.citygui-draft-tooltip"}, tags = {rts_citygui = "draft", city = c.id}})
  row.add({type = "empty-widget", style = "rts_hud_filler"})
  el.p_prio_toggle = row.add({type = "button", name = PREFIX .. "prio_toggle", style = "rts_hud_button",
    caption = {"rts-people.citygui-priorities"}, tooltip = {"rts-people.citygui-priorities-tooltip"},
    tags = {rts_citygui = "prio_toggle", city = c.id}})
  el.p_prio_toggle.style.height = 24
  -- Phase 5 M2 integration: two families per row (nine rows pushed the panel over the ability bar at 1280x800), each
  -- with one "up" button (moving a family down is moving the next one up): with both arrows the Russian names were cut
  -- and the right column's arrows stuck out of the panel
  el.p_prio = frame.add({type = "table", column_count = 4})
  el.p_prio.style.horizontal_spacing = 4
  el.p_prio.style.vertical_spacing = 0
  el.p_prio_key = nil
end

local function family_name(fam) return {"rts-people.family-" .. fam} end

local function refresh_priorities(g, c, open)
  local el = g.el
  local _, lab = people()
  local tbl = el.p_prio
  if not (lab and tbl and tbl.valid) then return end
  local list = open and lab.priorities(c.force) or {}
  local key = table.concat(list, ",")
  if el.p_prio_key == key then return end
  el.p_prio_key = key
  tbl.clear()
  for i, fam in ipairs(list) do
    local l = tbl.add({type = "label", style = "rts_hud_label", caption = {"rts-people.citygui-priority-row", i,
                       family_name(fam)}, tooltip = {"rts-people.family-" .. fam .. "-tooltip"}})
    l.style.width = math.floor(WIDTH / 2) - 42
    tbl.add({type = "sprite-button", name = PREFIX .. "prio_up_" .. fam, sprite = "utility/hint_arrow_up",
             style = "frame_action_button", tooltip = {"rts-people.citygui-priority-up"},
             tags = {rts_citygui = "prio_up", city = c.id, family = fam}}).enabled = i > 1
  end
end

local function refresh_people(player, g, c)
  local el = g.el
  local pop = people()
  if not (pop and el.p_pop and el.p_pop.valid) then return end
  local P = pop.of(c.id)
  if not P then return end
  el.p_pop.caption = {"rts-people.citygui-pop", P.pop, P.housing, string.format("%+.1f", P.growth or 0)}
  el.p_pop.style.font_color = P.free_housing <= 0 and COLOR.yellow or COLOR.white
  el.p_pop.tooltip = {"rts-people.citygui-pop-tooltip", P.free_housing, P.born and math.floor(P.born) or 0,
                      P.lost and math.floor(P.lost) or 0, P.drafted or 0, P.settled or 0}
  el.p_mood.caption = {"rts-people.citygui-mood", P.happiness,
    P.tier >= 2 and (P.power and {"rts-people.citygui-power-ok"} or {"rts-people.citygui-power-off"})
      or {"rts-people.citygui-power-village"}, P.unrest and {"rts-people.citygui-unrest"} or ""}
  el.p_mood.style.font_color = (P.unrest or P.happiness < 40) and COLOR.yellow or COLOR.white
  for item, r in pairs(el.p_bars or {}) do
    if r.bar.valid then
      local N = P.needs[item]
      if N then
        local pct = math.floor(math.min(1, N.met) * 100 + 0.5)
        r.bar.value = math.min(1, N.met)
        r.text.caption = {"rts-people.citygui-need", pct, string.format("%.1f", N.need)}
        r.text.style.font_color = N.met < PB.hold_at and COLOR.red or (N.met < PB.grow_at and COLOR.yellow or COLOR.dim)
      else
        r.bar.value = 0
        r.text.caption = {"rts-people.citygui-need-later"}
        r.text.style.font_color = COLOR.dim
      end
    end
  end
  -- Phase 5 M3 age3: automation kits make the jobs fractional (16 x 0.49)
  el.p_work.caption = {"rts-people.citygui-work", P.workforce, math.floor(P.employed + 0.5), math.floor(P.jobs + 0.5),
                       math.floor(P.free + 0.5), P.recruits}
  el.p_work.style.font_color = (P.starving or P.unrest) and COLOR.red
    or (P.jobs > P.employed + 0.5 and COLOR.yellow or COLOR.white)
  if el.p_draft and el.p_draft.valid then
    local best, bd = 1, math.huge
    for i, v in ipairs(PB.draft.levels) do
      local d = math.abs(v - (P.draft or 0))
      if d < bd then best, bd = i, d end
    end
    if el.p_draft.selected_index ~= best then el.p_draft.selected_index = best end
    local own = c.force == player.force.name
    el.p_draft.enabled = own
  end
  if el.p_prio_toggle and el.p_prio_toggle.valid then
    el.p_prio_toggle.toggled = g.prio_open == true
    el.p_prio_toggle.enabled = c.force == player.force.name
  end
  refresh_priorities(g, c, g.prio_open == true and c.force == player.force.name)
end

-- Staffing box: the selected own building with jobs (Nation mode)
local function destroy_staff(g)
  if g.staff and g.staff.valid then g.staff.destroy() end
  g.staff, g.staff_un, g.staff_el = nil, nil, nil
end

local function place_staff(player, frame)
  local s, res = player.display_scale, player.display_resolution
  frame.location = {math.floor(MARGIN * s + 0.5),
                    res.height - math.floor((HUD_PANEL_HEIGHT + MARGIN + 34 + 4) * s + 0.5)}
  -- 0.1.3 (#35): above the building page however tall it is (a factory tab with more rows grows the page upwards)
  local panel = player.gui.screen["rts_hud_panel"]
  if panel and panel.valid and panel.visible then
    frame.location = {math.floor(MARGIN * s + 0.5), panel.location.y - math.floor((34 + 4) * s + 0.5)}
  end
end

local function show_staff(player, g)
  local pop, lab = people()
  local un, rec = selection.get_building(player.index)
  local jobs = (pop and rec and rec.force == player.force.name and rec.entity.valid)
    and pop.jobs_of(rec.entity.name, rec.kind) or 0
  if not (nation_running() and lab and jobs > 0) then
    if g.staff then destroy_staff(g) end
    return
  end
  if g.staff_un ~= un or not (g.staff and g.staff.valid) then
    destroy_staff(g)
    local frame = player.gui.screen.add({type = "frame", name = STAFF, direction = "horizontal",
                                         style = "rts_hud_frame"})
    frame.style.width = STAFF_WIDTH
    local el = {}
    el.text = frame.add({type = "label", style = "rts_hud_label", caption = ""})
    el.text.style.maximal_width = STAFF_WIDTH - 90
    frame.add({type = "empty-widget", style = "rts_hud_filler"})
    el.pin = frame.add({type = "button", name = PREFIX .. "pin", style = "rts_hud_button", caption = "",
                        tags = {rts_citygui = "pin", un = un}})
    el.pin.style.height = 24
    g.staff, g.staff_un, g.staff_el = frame, un, el
    place_staff(player, frame)
  end
  local el = g.staff_el
  local step = lab.staffing(rec.entity)
  local city_id = pop.city_of_building(un)
  local c = city_id and cities.get(city_id)
  -- Phase 5 M3 age3: the jobs after the building's automation kits
  if lab.job_factor then jobs = jobs * lab.job_factor(rec.entity) end
  el.text.caption = {"rts-people.staff-line", math.floor(step * 100 + 0.5), string.format("%.1f", step * jobs),
                     string.format("%g", math.floor(jobs * 10 + 0.5) / 10), -- Phase 5 M3 integration: "7.8 of 7.8"
                     c and cities.display_name(c) or {"rts-people.staff-no-city"},
                     family_name(lab.family(rec.entity.name, rec.kind))}
  el.text.style.font_color = step <= 0 and COLOR.red or (step < 1 and COLOR.yellow or COLOR.white)
  el.text.tooltip = {"rts-people.staff-tooltip"}
  local pinned = lab.pinned(rec.entity)
  el.pin.caption = pinned and {"rts-people.unpin"} or {"rts-people.pin"}
  el.pin.tooltip = {"rts-people.pin-tooltip"}
  el.pin.toggled = pinned
end
-- end Phase 5 M2 people --------------------------------------------------------------------------------------------

local function build_panel(player, g, c)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el, g.city, g.targets = frame, {}, c.id, {}
  local el = g.el
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.title = row.add({type = "label", style = "rts_hud_heading_label", caption = "",
                      tooltip = {"rts.citygui-title-tooltip"}})
  el.title.style.maximal_width = WIDTH - 90
  row.add({type = "empty-widget", style = "rts_hud_filler"})
  row.add({type = "sprite-button", name = PREFIX .. "help_card", style = "frame_action_button", caption = "?", -- 0.1.2 (#30)
           tooltip = {"rts-help.card-pin-tooltip"}, tags = {rts_help = "rts-city-center"}})
  row.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
           tooltip = {"rts.citygui-close"}, tags = {rts_citygui = "close"}})
  -- Phase 5 M2 integration: "Under attack" (the last 30 s, or the centre subdued / being captured) and a Jump button
  local attack = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.attack_row = attack
  el.attack = attack.add({type = "label", style = "rts_hud_label", caption = ""})
  el.attack.style.font_color = COLOR.red
  el.attack.style.maximal_width = WIDTH - 80
  attack.add({type = "empty-widget", style = "rts_hud_filler"})
  el.attack_jump = attack.add({type = "button", name = PREFIX .. "attack_jump", style = "rts_hud_button",
    caption = {"rts.citygui-attack-jump"}, tooltip = {"rts.citygui-attack-jump-tooltip"},
    tags = {rts_citygui = "attack_jump", city = c.id}})
  el.attack_jump.style.height = 24
  attack.visible = false
  local rename = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.name = rename.add({type = "textfield", name = PREFIX .. "name", text = c.name or "", lose_focus_on_confirm = true,
    tooltip = {"rts.citygui-rename-tooltip"}, tags = {rts_citygui = "name", city = c.id}})
  el.name.style.width = WIDTH - 60
  -- Phase 5 M2 QA round 1: a city without its own name showed an empty field ("Capital" is a localised string, and a
  -- textfield takes plain text): the field gets the default name once the player's client has translated it
  g.default_name = nil
  g.name_req = not c.name and player.request_translation(cities.display_name(c)) or nil
  rename.add({type = "sprite-button", name = PREFIX .. "rename", sprite = "utility/rename_icon",
              style = "tool_button", tooltip = {"rts.citygui-rename"}, tags = {rts_citygui = "rename", city = c.id}})
  el.tier = label(frame, "rts_hud_label")
  el.age = label(frame, "rts_hud_label")
  el.land = label(frame, "rts_hud_label")
  el.supply = label(frame, "rts_hud_label")
  el.next = label(frame, "rts_hud_label")
  build_people(frame, el, c) -- Phase 5 M2 people
  el.networks = label(frame, "rts_hud_dim_label")
  el.waiting = label(frame, "rts_hud_label") -- 0.1.2 (#26): ghosts waiting for items in this city's network
  el.waiting.style.font_color = COLOR.red
  el.waiting.visible = false
  label(frame, "rts_hud_heading_label", {"rts.citygui-targets"})
  local tbl = frame.add({type = "table", column_count = 3})
  tbl.style.horizontal_spacing = 8
  tbl.style.vertical_spacing = 2
  el.targets = tbl
  local items = {}
  for item in pairs(c.make) do items[#items + 1] = item end
  table.sort(items)
  for _, item in ipairs(items) do add_target_row(g, item, c.make[item]) end
  local add = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.add = add.add({type = "sprite-button", name = PREFIX .. "add", sprite = "utility/add", style = "slot_button",
                    tooltip = {"rts.citygui-target-add"}, tags = {rts_citygui = "add", city = c.id}})
  label(add, "rts_hud_dim_label", {"rts.citygui-target-hint"}, WIDTH - 60)
  -- Demolish the City Center (two presses, scripts/demolish.lua); the capital cannot be demolished (greyed)
  local foot = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  if citygui.foot_hook then citygui.foot_hook(foot, el, c) end -- Phase 5 M3 age3: Hire garrison (scripts/sinks.lua)
  foot.add({type = "empty-widget", style = "rts_hud_filler"})
  el.demolish = foot.add({type = "button", name = PREFIX .. "demolish", style = "rts_hud_button",
    caption = {"rts.demolish"}, tags = {rts_citygui = "demolish", city = c.id}})
  el.demolish.style.height = 24
  place_panel(player, frame)
end

-- Phase 5 M2 integration: what the "under attack" line says for city c (own cities only), or nil.
local function attack_text(c)
  local cap = package.loaded["__" .. script.mod_name .. "__/scripts/capture.lua"]
  local cs = cap and cap.of and cap.of(c.id)
  if cs and cs.subdued then
    if cs.capturing and cs.progress then
      return {"rts.citygui-attack-capture", match.label(cs.capturing),
              math.floor(100 * cs.progress / math.max(1, CAPTURE_TICKS))}
    end
    return {"rts.citygui-attack-subdued"}
  end
  local a = cities.under_attack(c.id)
  if a then return {"rts.citygui-attack", math.floor((game.tick - a.tick) / 60)} end
  return nil
end

local function attack_position(c)
  local a = storage.city_attacks and storage.city_attacks[c.id]
  return a and a.position or c.position
end

local function refresh_panel(player, g)
  local c = cities.get(g.city)
  if not c then return false end
  local el = g.el
  el.title.caption = {"rts.citygui-title", cities.display_name(c), tier_name(c.tier)}
  if el.attack_row and el.attack_row.valid then -- Phase 5 M2 integration
    local text = c.force == player.force.name and attack_text(c) or nil
    el.attack_row.visible = text ~= nil
    if text then el.attack.caption = text end
  end
  el.tier.caption = {"rts.citygui-tier", tier_name(c.tier), c.radius, c.capital and {"rts.citygui-capital"} or ""}
  -- the nation's age: storage.ages (scripts/ages.lua, m1-economy), else storage.nations[force].age
  local ages = storage.ages and storage.ages[c.force]
  local nation = storage.nations and storage.nations[c.force]
  local age = (type(ages) == "table" and ages.age) or (nation and nation.age) or 1
  el.age.caption = {"rts.citygui-age", age}
  local cells = territory.city_cells(c.id)
  local own = math.max(1, territory.cells(c.force))
  el.land.caption = {"rts.citygui-land", cells, string.format("%d", math.floor(cells * 100 / own + 0.5))}
  el.supply.caption = {"rts.citygui-supply", cities.supply_total(c)}
  local pop = people() -- Phase 5 M2 people: the next tier comes from the population
  local P = pop and pop.of(c.id)
  local req = not P and cities.next_tier(c)
  if P and P.next_at then
    el.next.caption = {"rts-people.citygui-next", tier_name(c.tier + 1), P.next_at, P.pop}
    el.next.style.font_color = COLOR.white
  elseif req then
    el.next.caption = {"rts.citygui-next", tier_name(c.tier + 1), c.buildings or 0, req.buildings,
                       math.floor(c.delivered or 0), req.delivered}
    el.next.style.font_color = COLOR.white
  else
    el.next.caption = {"rts.citygui-top"}
    el.next.style.font_color = COLOR.green
  end
  local ids = {}
  for _, id in ipairs(c.networks or {}) do ids[#ids + 1] = "#" .. id end
  el.networks.caption = {"rts.citygui-networks", #ids, #ids > 0 and table.concat(ids, " ") or "-"}
  local waiting = netwait.line(c.center)
  if el.waiting and el.waiting.valid then
    el.waiting.visible = waiting ~= nil
    if waiting then
      el.waiting.caption = waiting
      el.waiting.tooltip = {"rts-ux.waiting-tooltip"}
    end
  end
  refresh_people(player, g, c) -- Phase 5 M2 people
  if citygui.refresh_hook then citygui.refresh_hook(player, el, c) end -- Phase 5 M3 age3
  local b = el.demolish
  if b and b.valid then
    local rec = c.force == player.force.name and buildings.get(c.center) or nil
    local blocked = not rec or buildings.demolish_blocked(rec) ~= nil
    local armed = not blocked and demolish.is_armed(player.index, {c.center})
    b.enabled = not blocked
    b.style = armed and "rts_hud_button_armed" or "rts_hud_button"
    b.style.height = 24
    b.caption = armed and {"rts.demolish-confirm"} or {"rts.demolish"}
    b.tooltip = blocked and {"rts.demolish-tooltip-blocked"}
      or {"rts.demolish-tooltip", math.floor(buildings.REFUND_RATIO * 100)}
  end
  return true
end

local function show_panel(player, force_rebuild)
  local g = pstate(player.index)
  if not nation_running() then
    if g.frame then destroy_panel(g, player) end
    return
  end
  local c = selected_city(player)
  local key = c and ("sel:" .. c.id) or nil
  if not c and g.pinned then
    c = cities.get(g.pinned)
    -- Phase 5 M2 integration: a pinned city that changed hands (captured) closes its panel
    if c and c.force ~= player.force.name then c = nil end
    key = c and ("pin:" .. c.id) or nil
    if not c then g.pinned = nil end
  end
  if g.closed and g.closed ~= key then g.closed = nil end
  if not c or g.closed == key then
    if g.frame then destroy_panel(g, player) end
    return
  end
  if force_rebuild or g.key ~= key or not (g.frame and g.frame.valid) then
    destroy_panel(g, g.key ~= key and player or nil) -- the picker stays open over a rebuild of the same city
    build_panel(player, g, c)
    g.key = key
    util.log("citygui: city panel %d (%s) player=%d", c.id, key, player.index)
  end
  if not refresh_panel(player, g) then destroy_panel(g, player) end
end

---------------------------------------------------------------------------
-- City list
---------------------------------------------------------------------------
local function destroy_list(g)
  if g.list and g.list.valid then g.list.destroy() end
  g.list, g.list_rows, g.list_key = nil, nil, nil
end

local function place_list(player, frame)
  local s = player.display_scale
  frame.location = {math.floor(MARGIN * s + 0.5), math.floor(LIST_TOP * s + 0.5)}
end

local function build_list(player, g, list)
  local frame = player.gui.screen.add({type = "frame", name = LIST, direction = "vertical", style = "rts_hud_feed_frame"})
  frame.style.width = LIST_WIDTH
  g.list, g.list_rows = frame, {}
  local head = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  head.add({type = "label", style = "rts_hud_heading_label", caption = {"rts.citygui-list-title"},
            tooltip = {"rts.citygui-list-tooltip"}})
  g.list_share = head.add({type = "label", style = "rts_hud_dim_label", caption = ""})
  for _, c in ipairs(list) do
    local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    local jump = row.add({type = "button", name = PREFIX .. "jump_" .. c.id, caption = cities.display_name(c),
      style = "rts_hud_button", tooltip = {"rts.citygui-jump-tooltip"}, tags = {rts_citygui = "jump", city = c.id}})
    jump.style.maximal_width = 170 -- Phase 5 M2 integration: room for the attack mark (LIST_WIDTH 300)
    jump.style.height = 24
    jump.style.padding = {0, 4}
    local info = row.add({type = "label", style = "rts_hud_mono_label", caption = ""})
    row.add({type = "empty-widget", style = "rts_hud_filler"})
    row.add({type = "sprite-button", name = PREFIX .. "open_" .. c.id, sprite = "utility/search",
      style = "frame_action_button", tooltip = {"rts.citygui-open-tooltip"}, tags = {rts_citygui = "open", city = c.id}})
    g.list_rows[c.id] = {jump = jump, info = info}
  end
  place_list(player, frame)
end

local function show_list(player)
  local g = pstate(player.index)
  if not nation_running() or g.list_hidden then
    if g.list then destroy_list(g) end
    return
  end
  local list = cities.for_force(player.force.name)
  local ids = {}
  for _, c in ipairs(list) do ids[#ids + 1] = c.id .. ":" .. (c.name or "") end
  local key = table.concat(ids, ",")
  if g.list_key ~= key or not (g.list and g.list.valid) then
    destroy_list(g)
    build_list(player, g, list)
    g.list_key = key
  end
  for _, c in ipairs(list) do
    local r = g.list_rows[c.id]
    if r and r.info.valid then
      r.info.caption = {"rts.citygui-list-row", tier_name(c.tier), territory.city_cells(c.id)}
      -- Phase 5 M2 integration: a city under attack (or subdued) is marked; the button jumps to the attack
      -- (a red caption was unreadable on the grey button: a danger icon before the name instead)
      local hit = attack_text(c) ~= nil
      r.jump.caption = hit and {"", "[img=utility/danger_icon] ", cities.display_name(c)} or cities.display_name(c)
      r.jump.tooltip = hit and {"rts.citygui-jump-attack-tooltip"} or {"rts.citygui-jump-tooltip"}
    end
  end
  if g.list_share and g.list_share.valid then
    g.list_share.caption = {"rts.territory-share-short",
                            string.format("%.1f", territory.share(player.force.name) * 100)}
  end
end

--- Show or hide the city list (the HUD strip's Cities button).
function citygui.toggle_list(player)
  local g = pstate(player.index)
  g.list_hidden = not g.list_hidden or nil
  util.log("citygui: city list %s player=%d", g.list_hidden and "hidden" or "shown", player.index)
  show_list(player)
end

--- Open the city panel of a city (pinned until closed).
function citygui.open(player, city_id)
  local g = pstate(player.index)
  g.pinned, g.closed = city_id, nil
  show_panel(player, true)
end

function citygui.refresh(player_index, force_rebuild)
  local player = game.get_player(player_index)
  if player and player.connected then
    show_panel(player, force_rebuild)
    show_list(player)
  end
end

events.on_nth_tick(POLL_PERIOD, function(e)
  local refresh = e.tick % REFRESH_PERIOD == 0
  for _, player in pairs(game.connected_players) do
    local p = storage.players and storage.players[player.index]
    local g = p and p.citygui
    if nation_running() or (g and (g.frame or g.list or g.staff)) then -- Phase 5 M2 people: g.staff
      local c = nation_running() and selected_city(player)
      local key = c and ("sel:" .. c.id) or (g and g.pinned and ("pin:" .. g.pinned)) or nil
      if refresh or (g and g.key) ~= key then
        show_panel(player)
        if refresh then show_list(player) end
      end
      -- Phase 5 M2 people: the staffing box follows the selected building
      if g and (refresh or g.staff_un ~= selection.get_building(player.index)) then show_staff(player, g) end
    end
  end
end)

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local function rename(player, g, city_id)
  local el = g.el
  if not (el and el.name and el.name.valid) then return end
  local text = el.name.text
  if g.default_name and text == g.default_name then text = "" end -- Phase 5 M2 QA round 1: the default name stays one
  cities.rename(city_id, text)
  util.log("citygui click rename city=%d name=%s player=%d", city_id, text, player.index)
  show_panel(player, true) -- Phase 5 M2 QA round 1: rebuilt, so an emptied field shows the default name again
  show_list(player)
  -- Phase 5 M1 integration: the hub panel's title names the city too (logistics.NAME_HOOKS): rebuild it
  if hubgui then hubgui.refresh(player.index, true) end
end

events.on(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = element.tags
  local action = tags.rts_citygui
  local player = game.get_player(e.player_index)
  local g = pstate(e.player_index)
  if action == "close" then
    g.closed, g.pinned = g.key, nil
    destroy_panel(g, player)
  elseif action == "add" then
    -- QA round 1: the scripted picker, left of the panel (a choose-elem-button took the rts-cursor from the cursor)
    local loc
    if g.frame and g.frame.valid and g.frame.location then
      local s = player.display_scale
      loc = {math.max(0, g.frame.location.x - math.floor((itempicker.WIDTH + MARGIN) * s + 0.5)), g.frame.location.y}
    end
    itempicker.open(player, "citygui", {city = tags.city}, loc)
  elseif action == "target" then
    element.select_all() -- QA round 1: typing replaces the value
    return
  elseif action == "rename" then
    rename(player, g, tags.city)
  elseif action == "remove" then
    cities.set_make_target(tags.city, tags.item, nil)
    show_panel(player, true)
  elseif action == "jump" then
    local c = cities.get(tags.city)
    -- Phase 5 M2 integration: a city under attack jumps to the attack
    if c then camera.jump_to(player, attack_text(c) and attack_position(c) or c.position) end
  elseif action == "attack_jump" then -- Phase 5 M2 integration
    local c = cities.get(tags.city)
    if c then camera.jump_to(player, attack_position(c)) end
  elseif action == "open" then
    citygui.open(player, tags.city)
  elseif action == "prio_toggle" then -- Phase 5 M2 people
    g.prio_open = not g.prio_open or nil
    show_panel(player)
  elseif action == "prio_up" or action == "prio_down" then
    local c, lab = cities.get(tags.city), cities.labor
    if c and lab and c.force == player.force.name then
      lab.move_priority(c.force, tags.family, action == "prio_up" and -1 or 1)
    end
    show_panel(player)
  elseif action == "pin" then
    local lab = cities.labor
    local rec = buildings.get(tags.un)
    if lab and rec and rec.force == player.force.name then lab.pin(rec.entity, not lab.pinned(rec.entity)) end
    show_staff(player, g)
  elseif action == "demolish" then
    local c = cities.get(tags.city)
    local result = c and demolish.click(player, {c.center}) or "none"
    util.log("citygui click demolish city=%s result=%s player=%d", tostring(tags.city), tostring(result), e.player_index)
    show_panel(player)
    show_list(player)
    return
  else
    return
  end
  util.log("citygui click %s city=%s player=%d", tostring(action), tostring(tags.city), e.player_index)
end)

events.on(defines.events.on_gui_confirmed, function(e)
  local element = e.element
  if not (element and element.valid) or element.tags.rts_citygui ~= "name" then return end
  rename(game.get_player(e.player_index), pstate(e.player_index), element.tags.city)
end)

-- Phase 5 M2 QA round 1: the default name for the name field (see build_panel)
events.on(defines.events.on_string_translated, function(e)
  local g = storage.players and storage.players[e.player_index] and storage.players[e.player_index].citygui
  if not (g and g.name_req and g.name_req == e.id) then return end
  g.name_req = nil
  local field = g.el and g.el.name
  if not (e.translated and field and field.valid) or field.text ~= "" then return end
  field.text = e.result
  g.default_name = e.result
end)

events.on(defines.events.on_gui_text_changed, function(e)
  local element = e.element
  if not (element and element.valid) or element.tags.rts_citygui ~= "target" then return end
  local text = element.text or ""
  local ok = cities.set_make_target(element.tags.city, element.tags.item, text ~= "" and tonumber(text) or nil)
  util.log("citygui target city=%d %s=%s ok=%s player=%d", element.tags.city, element.tags.item, text, tostring(ok),
    e.player_index)
end)

-- The picker's choice: a new row (empty field, focused with its text selected) unless the city has that target.
itempicker.on_pick("citygui", function(player, item, ctx)
  local g = pstate(player.index)
  local c = cities.get(ctx.city)
  if not (c and g.frame and g.frame.valid and g.city == c.id) then return end
  if not c.make[item] then add_target_row(g, item, nil) end
  local tf = g.targets and g.targets[item]
  if tf and tf.valid then
    tf.focus()
    tf.select_all()
  end
  util.log("citygui add target city=%d item=%s player=%d", c.id, item, player.index)
end)

-- Phase 5 M2 people: the draft drop-down
events.on(defines.events.on_gui_selection_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or element.tags.rts_citygui ~= "draft" then return end
  local player = game.get_player(e.player_index)
  local c, pop = cities.get(element.tags.city), cities.people
  local level = PB.draft.levels[element.selected_index]
  if c and pop and level and player and c.force == player.force.name then pop.set_draft(c.id, level) end
  util.log("citygui draft city=%s level=%s player=%d", tostring(element.tags.city), tostring(level), e.player_index)
end)

local function reposition(e)
  local player = game.get_player(e.player_index)
  local g = player and pstate(player.index)
  if not g then return end
  if g.frame and g.frame.valid then place_panel(player, g.frame) end
  if g.list and g.list.valid then place_list(player, g.list) end
  if g.staff and g.staff.valid then place_staff(player, g.staff) end -- Phase 5 M2 people
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

function citygui.init()
  for _, p in pairs(storage.players or {}) do
    local g = p.citygui
    if g then
      if g.frame and g.frame.valid then g.frame.destroy() end
      if g.list and g.list.valid then g.list.destroy() end
      if g.staff and g.staff.valid then g.staff.destroy() end -- Phase 5 M2 people
      p.citygui = {list_hidden = g.list_hidden}
    end
  end
end

return citygui
