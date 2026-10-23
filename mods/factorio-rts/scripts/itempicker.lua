-- Make-target item picker (Phase 5 M1 QA round 1, finding 1; docs/qa/phase5-m1-integration-notes.md "QA round 1
-- fixes"). Nation mode only: the city panel (citygui.lua) and the city ledger (ledgergui.lua) open it.
--
-- Why not a choose-elem-button: in this mod the player's cursor always holds the rts-cursor selection tool, and a
-- vanilla item chooser clicked with an item in the cursor takes that item instead of opening its picker, so every
-- click set "rts-cursor" as the target (QA steps 15 and 43). This picker is a small screen frame with one sprite button
-- per good a city can make: the item products of the non-hidden recipes that factories and districts can run (the
-- recipes the auto-recipe pass of production.lua chooses from), minus hidden items and cursor-only tools. Goods whose
-- recipes the player's force has unlocked come first ("Can make now"), the rest after ("After research").
--
-- API: itempicker.open(player, owner, ctx, location?) shows it (one per player; opening it again for the same owner
-- closes it), itempicker.close(player[, owner]), itempicker.is_open(player[, owner]), itempicker.allowed(item),
-- itempicker.list(), and itempicker.on_pick(owner, fn) where fn(player, item, ctx) runs when a good is clicked (the
-- picker closes first). `owner` is "citygui" or "ledger"; `ctx` is a plain table stored with the picker ({city = id}).
-- Owns util.pstorage(i).itempicker = {owner, ctx}. Element names start with "rts_itempicker_". Texts: [rts] keys
-- "itempicker-*" (locale/*/cities.cfg). QA log lines start with "itempicker: ".
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")

local itempicker = {}

itempicker.FRAME = "rts_itempicker"
local PREFIX = "rts_itempicker_"
local COLUMNS = 10
local SLOT = 40               -- slot_button size
local MAX_ROWS_HEIGHT = 7 * SLOT
local WIDTH = COLUMNS * SLOT + 28
itempicker.WIDTH = WIDTH      -- GUI units (callers scale by player.display_scale to place it)
local CRAFTER_KINDS = {factory = true, district = true} -- production.lua CRAFTER: the machines with auto recipes

local handlers = {} -- [owner] = fn(player, item, ctx); registered at load time

-- Static prototype data, identical on every client and not saved: built on first use (all modules have registered
-- their building kinds by then).
local allowed_list, allowed_set, recipes_by_item

local function sort_key(item)
  local p = prototypes.item[item]
  local g, sg = p.group, p.subgroup
  return (g and g.order or "") .. "|" .. (g and g.name or "") .. "|" .. (sg and sg.order or "") .. "|"
    .. (sg and sg.name or "") .. "|" .. (p.order or "") .. "|" .. item
end

local function excluded(proto)
  if not proto or proto.hidden or proto.name == util.CURSOR_ITEM then return true end
  local ok, cursor_only = pcall(function() return proto.has_flag("only-in-cursor") end)
  return ok and cursor_only == true
end

local function build_allowed()
  allowed_list, allowed_set, recipes_by_item = {}, {}, {}
  local cats = {}
  for name, kind in pairs(buildings.KIND_BY_NAME) do
    if CRAFTER_KINDS[kind] then
      local proto = prototypes.entity[name]
      for cat in pairs(proto and proto.crafting_categories or {}) do cats[cat] = true end
    end
  end
  for rname, r in pairs(prototypes.recipe) do
    if util.recipe_in(r, cats) and not r.hidden and not r.parameter then -- 2.1: categories
      for _, p in ipairs(r.products) do
        if p.type == "item" and not excluded(prototypes.item[p.name]) then
          if not allowed_set[p.name] then
            allowed_set[p.name] = true
            allowed_list[#allowed_list + 1] = p.name
            recipes_by_item[p.name] = {}
          end
          table.insert(recipes_by_item[p.name], rname)
        end
      end
    end
  end
  local keys = {}
  for _, item in ipairs(allowed_list) do keys[item] = sort_key(item) end
  table.sort(allowed_list, function(a, b) return keys[a] < keys[b] end)
end

--- Sorted item names a city can have as a make target.
function itempicker.list()
  if not allowed_list then build_allowed() end
  return allowed_list
end

--- True when `item` can be a make target (a factory or district recipe makes it; not hidden, not a cursor tool).
function itempicker.allowed(item)
  if not allowed_set then build_allowed() end
  return type(item) == "string" and allowed_set[item] == true
end

--- True when the force has unlocked a recipe that makes `item`.
function itempicker.unlocked(force, item)
  if not recipes_by_item then build_allowed() end
  local fr = force.recipes
  for _, rname in ipairs(recipes_by_item[item] or {}) do
    local r = fr[rname]
    if r and r.enabled then return true end
  end
  return false
end

--- Register the pick handler of an owner ("citygui", "ledger"). Load time only.
function itempicker.on_pick(owner, fn) handlers[owner] = fn end

local function pstate(player_index)
  local p = util.pstorage(player_index)
  p.itempicker = p.itempicker or {}
  return p.itempicker
end

--- True while the picker is open (for `owner`, when given).
function itempicker.is_open(player, owner)
  local frame = player.gui.screen[itempicker.FRAME]
  if not (frame and frame.valid) then return false end
  return owner == nil or pstate(player.index).owner == owner
end

--- Close the picker (only when it belongs to `owner`, when given).
function itempicker.close(player, owner)
  local s = pstate(player.index)
  if owner and s.owner ~= owner then return end
  local frame = player.gui.screen[itempicker.FRAME]
  if frame and frame.valid then frame.destroy() end
  s.owner, s.ctx = nil, nil
end

local function add_section(parent, player, caption, items)
  if #items == 0 then return end
  local head = parent.add({type = "label", style = "caption_label", caption = caption})
  head.style.top_margin = 4
  local deep = parent.add({type = "frame", style = "slot_button_deep_frame"})
  local tbl = deep.add({type = "table", column_count = COLUMNS, style = "filter_slot_table"})
  for _, item in ipairs(items) do
    local proto = prototypes.item[item]
    local unlocked = itempicker.unlocked(player.force, item)
    tbl.add({type = "sprite-button", name = PREFIX .. "pick_" .. item, sprite = "item/" .. item, style = "slot_button",
      tooltip = unlocked and {"rts.itempicker-item", proto.localised_name}
        or {"rts.itempicker-item-locked", proto.localised_name},
      tags = {rts_itempicker = "pick", item = item}})
  end
end

--- Open the picker for `owner` with context `ctx`. `location` (pixels) places it; without one it is centred.
--- A second open for the same owner closes it (the add button toggles). Returns the frame or nil.
function itempicker.open(player, owner, ctx, location)
  local s = pstate(player.index)
  if itempicker.is_open(player, owner) then
    itempicker.close(player)
    util.log("itempicker: closed (toggle) owner=%s player=%d", owner, player.index)
    return nil
  end
  itempicker.close(player)
  local frame = player.gui.screen.add({type = "frame", name = itempicker.FRAME, direction = "vertical"})
  frame.style.width = WIDTH
  local bar = frame.add({type = "flow", direction = "horizontal"})
  bar.drag_target = frame
  bar.add({type = "label", caption = {"rts.itempicker-title"}, style = "frame_title", ignored_by_interaction = true})
  local drag = bar.add({type = "empty-widget", style = "draggable_space_header"})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  bar.add({type = "sprite-button", name = PREFIX .. "close", style = "frame_action_button", sprite = "utility/close",
           tooltip = {"rts.itempicker-close"}, tags = {rts_itempicker = "close"}})
  local hint = frame.add({type = "label", caption = {"rts.itempicker-hint"}})
  hint.style.single_line = false
  hint.style.maximal_width = WIDTH - 24
  local scroll = frame.add({type = "scroll-pane", vertical_scroll_policy = "auto", horizontal_scroll_policy = "never"})
  scroll.style.maximal_height = MAX_ROWS_HEIGHT + 60
  local now, later = {}, {}
  for _, item in ipairs(itempicker.list()) do
    if itempicker.unlocked(player.force, item) then now[#now + 1] = item else later[#later + 1] = item end
  end
  add_section(scroll, player, {"rts.itempicker-now"}, now)
  add_section(scroll, player, {"rts.itempicker-later"}, later)
  if location then frame.location = location else frame.auto_center = true end
  s.owner, s.ctx = owner, ctx or {}
  util.log("itempicker: opened owner=%s ctx=%s player=%d items=%d now=%d", owner, serpent.line(s.ctx), player.index,
    #now + #later, #now)
  return frame
end

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local action = el.tags and el.tags.rts_itempicker
  local player = game.get_player(e.player_index)
  if not (player and action) then return end
  local s = pstate(player.index)
  if action == "close" then
    util.log("itempicker: closed owner=%s player=%d", tostring(s.owner), player.index)
    itempicker.close(player)
  elseif action == "pick" then
    local item, owner, ctx = el.tags.item, s.owner, s.ctx
    itempicker.close(player)
    local fn = owner and handlers[owner]
    local ok = fn ~= nil and itempicker.allowed(item)
    util.log("itempicker: pick %s owner=%s ok=%s player=%d", tostring(item), tostring(owner), tostring(ok),
      player.index)
    if ok then fn(player, item, ctx or {}) end
  end
end)

function itempicker.init()
  for index, p in pairs(storage.players or {}) do
    if p.itempicker then
      p.itempicker = nil
      local player = game.get_player(index)
      local frame = player and player.gui.screen[itempicker.FRAME]
      if frame and frame.valid then frame.destroy() end
    end
  end
end

return itempicker
