-- Phase 5 M2 market panel (docs/PHASE5-M2.md section 3 "treasury.lua / market.lua"; docs/qa/phase5-treasury-notes.md).
-- Nation mode only. M (custom input rts-market, through hud.lua's key table P4.KEYS) or a click on the treasury in the
-- HUD strip toggles it.
--
--   top       treasury: balance and net per minute (red in deficit), the tax level drop-down, the debt stage; income
--             and expenses of the last minute; the commerce cap (used / cap per minute, a bar), the Commerce level and
--             the port the Sell / Buy buttons trade at (drop-down of the player's ports)
--   goods     one row per tradeable good: price (green above its base price, red below), a 10-minute sparkline, the
--             count at the selected port, an amount field and Sell / Buy buttons (tooltips quote the amount now)
--   contracts the force's contracts (seller, buyer, good, deliveries, next due, state) and the imports on their way
-- Refreshed every REFRESH ticks while open; the goods rows are built once per open (their values are updated in place,
-- so an amount being typed keeps its focus). Owns util.pstorage(i).market_gui = {frame, port, ...}.
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local treasury = require("scripts.treasury")
local market = require("scripts.market")

local marketgui = {}

marketgui.FRAME = "rts_market"
marketgui.REFRESH = 60
marketgui.WIDTH = 880
marketgui.HEIGHT = 640
marketgui.DEFAULT_AMOUNT = 100
local GREY = {r = 0.7, g = 0.7, b = 0.7}
local RED = {r = 1, g = 0.45, b = 0.4}
local GREEN = {r = 0.5, g = 1, b = 0.5}
local YELLOW = {r = 1, g = 0.85, b = 0.3}
local WHITE = {r = 1, g = 1, b = 1}
local SPARK = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
local LEVELS = treasury.LEVELS

local function pstate(player_index)
  local ps = util.pstorage(player_index)
  ps.market_gui = ps.market_gui or {}
  return ps.market_gui
end

local function visible_for(player)
  return market.nation() and not match.in_lobby() and player.force ~= nil and match.is_participant(player.force.name)
end

local function cr(v) return treasury.fmt(v) end

local function sparkline(list)
  if #list < 2 then return "" end
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(list) do
    lo = math.min(lo, v)
    hi = math.max(hi, v)
  end
  local out = {}
  for i, v in ipairs(list) do
    local k = (hi - lo) < 1e-9 and 4 or (1 + math.floor((v - lo) / (hi - lo) * 7 + 0.5))
    out[i] = SPARK[math.max(1, math.min(8, k))]
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------
local function build_goods(g)
  local tbl = g.table
  tbl.clear()
  g.rows = {}
  for _, key in ipairs({"good", "price", "trend", "port", "amount", "sell", "buy"}) do
    local head = tbl.add({type = "label", caption = {"rts-treasury.market-col-" .. key}, style = "caption_label"})
    head.style.font_color = GREY
  end
  for _, item in ipairs(market.items()) do
    local proto = prototypes.item[item]
    local el = {}
    el.good = tbl.add({type = "label", caption = {"", "[item=" .. item .. "] ", proto.localised_name}})
    el.good.style.width = 210
    el.price = tbl.add({type = "label", caption = ""})
    el.price.style.width = 70
    el.price.style.horizontal_align = "right"
    el.trend = tbl.add({type = "label", caption = ""})
    el.trend.style.width = 110
    el.port = tbl.add({type = "label", caption = ""})
    el.port.style.width = 60
    el.port.style.horizontal_align = "right"
    el.amount = tbl.add({type = "textfield", text = tostring(marketgui.DEFAULT_AMOUNT), numeric = true,
                         allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true,
                         tags = {rts_market = "amount", item = item}})
    el.amount.style.width = 70
    el.sell = tbl.add({type = "button", caption = {"rts-treasury.market-sell"}, tags = {rts_market = "sell", item = item}})
    el.sell.style.minimal_width = 60
    el.buy = tbl.add({type = "button", caption = {"rts-treasury.market-buy"}, tags = {rts_market = "buy", item = item}})
    el.buy.style.minimal_width = 60
    g.rows[item] = el
  end
end

function marketgui.open(player)
  if not visible_for(player) then return nil end
  local screen = player.gui.screen
  if screen[marketgui.FRAME] then screen[marketgui.FRAME].destroy() end
  local ps = pstate(player.index)
  local frame = screen.add({type = "frame", name = marketgui.FRAME, direction = "vertical"})
  frame.style.width = marketgui.WIDTH
  frame.style.maximal_height = marketgui.HEIGHT
  local bar = frame.add({type = "flow", direction = "horizontal"})
  bar.drag_target = frame
  bar.add({type = "label", caption = {"rts-treasury.market-title"}, style = "frame_title", ignored_by_interaction = true})
  local drag = bar.add({type = "empty-widget", style = "draggable_space_header"})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  bar.add({type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
           tooltip = {"rts-treasury.market-close"}, tags = {rts_market = "close"}})

  local top = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  top.style.horizontally_stretchable = true
  local row1 = top.add({type = "flow", direction = "horizontal"})
  row1.style.vertical_align = "center"
  row1.style.horizontal_spacing = 12
  local balance = row1.add({type = "label", caption = ""})
  balance.style.font = "default-large-bold"
  row1.add({type = "label", caption = {"rts-treasury.market-tax"}})
  local items = {}
  for i, level in ipairs(LEVELS) do items[i] = {"rts-treasury.tax-" .. level} end
  local tax = row1.add({type = "drop-down", items = items, selected_index = 2, tags = {rts_market = "tax"},
                        tooltip = {"rts-treasury.market-tax-tooltip"}})
  tax.style.width = 110
  local stage = row1.add({type = "label", caption = ""})
  stage.style.single_line = false
  stage.style.maximal_width = 380
  local flows = top.add({type = "label", caption = ""})
  flows.style.single_line = false
  flows.style.maximal_width = marketgui.WIDTH - 40
  flows.style.font_color = GREY
  local row3 = top.add({type = "flow", direction = "horizontal"})
  row3.style.vertical_align = "center"
  row3.style.horizontal_spacing = 10
  row3.add({type = "label", caption = {"rts-treasury.market-cap"}, tooltip = {"rts-treasury.market-cap-tooltip"}})
  local cap_bar = row3.add({type = "progressbar", value = 0})
  cap_bar.style.width = 160
  local cap = row3.add({type = "label", caption = ""})
  row3.add({type = "label", caption = {"rts-treasury.market-port"}})
  local port = row3.add({type = "drop-down", items = {}, tags = {rts_market = "port"}})
  port.style.width = 220
  local port_hint = top.add({type = "label", caption = ""})
  port_hint.style.single_line = false
  port_hint.style.maximal_width = marketgui.WIDTH - 40
  port_hint.style.font_color = YELLOW

  local body = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  body.style.top_margin = 6
  local scroll = body.add({type = "scroll-pane", vertical_scroll_policy = "auto", horizontal_scroll_policy = "never"})
  scroll.style.maximal_height = 300
  local tbl = scroll.add({type = "table", column_count = 7})
  tbl.style.horizontal_spacing = 8
  tbl.style.vertical_spacing = 2

  local foot = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  foot.style.top_margin = 6
  foot.add({type = "label", caption = {"rts-treasury.market-contracts"}, style = "caption_label"})
  local contracts = foot.add({type = "label", caption = ""})
  contracts.style.single_line = false
  contracts.style.maximal_width = marketgui.WIDTH - 40
  local imports = foot.add({type = "label", caption = ""})
  imports.style.single_line = false
  imports.style.maximal_width = marketgui.WIDTH - 40
  imports.style.font_color = GREY

  ps.gui = {frame = frame, balance = balance, tax = tax, stage = stage, flows = flows, cap_bar = cap_bar, cap = cap,
            port_dd = port, port_hint = port_hint, table = tbl, contracts = contracts, imports = imports, rows = {},
            ports = {}}
  build_goods(ps.gui)
  frame.auto_center = true
  player.opened = frame
  marketgui.refresh(player)
  util.log("market: panel opened by player %d (%s)", player.index, player.force.name)
  return frame
end

function marketgui.close(player)
  local frame = player.gui.screen[marketgui.FRAME]
  if frame then frame.destroy() end
  pstate(player.index).gui = nil
end

function marketgui.toggle(player)
  if player.gui.screen[marketgui.FRAME] then marketgui.close(player) else marketgui.open(player) end
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function contract_line(f, c)
  local other = c.seller == f and c.buyer or c.seller
  local due = c.state == "active" and math.max(0, math.ceil((c.next_due - game.tick) / 60)) or 0
  return {"", "\n", {"rts-treasury.market-contract-line", c.id,
    {c.seller == f and "rts-treasury.market-contract-sell" or "rts-treasury.market-contract-buy"},
    match.label(other), c.n, "[item=" .. c.item .. "]", string.format("%.2f", c.price), c.done, c.missed,
    c.deliveries, due, {"rts-treasury.contract-state-" .. c.state}}}
end

function marketgui.refresh(player)
  local ps = pstate(player.index)
  local g = ps.gui
  if not (g and g.frame and g.frame.valid) then return end
  local f = player.force.name
  -- treasury
  local t = treasury.get(f)
  g.balance.caption = {"rts-treasury.market-balance", cr(t.balance), (t.net >= 0 and "+" or "-") .. cr(math.abs(t.net))}
  g.balance.style.font_color = t.balance < 0 and RED or (t.net < 0 and YELLOW or WHITE)
  for i, level in ipairs(LEVELS) do
    if level == t.tax and g.tax.selected_index ~= i then g.tax.selected_index = i end
  end
  g.stage.caption = {"rts-treasury.stage-" .. (t.stage or 0)}
  g.stage.style.font_color = (t.stage or 0) > 0 and RED or GREEN
  local i, e = t.income, t.expenses
  g.flows.caption = {"rts-treasury.market-flows", cr(i.tax), cr(i.exports), cr(i.other), cr(e.buildings), cr(e.army),
    cr(e.transport), cr(e.imports), cr(e.interest), cr(e.other), cr(t.credit), math.floor(t.pop or 0)}
  -- cap and ports
  local cap, used = market.cap(f), market.cap_used(f)
  g.cap_bar.value = cap > 0 and math.min(1, used / cap) or 0
  g.cap.caption = {"rts-treasury.market-cap-value", cr(used), cr(cap), market.commerce_level(f)}
  local ports = market.ports(f)
  local key = table.concat(ports, ",")
  if key ~= g.ports_key then
    local names = {}
    for k, un in ipairs(ports) do
      local p = market.port(un)
      names[k] = p and p.name or tostring(un)
    end
    g.port_dd.items = names
    g.ports_key, g.ports = key, ports
  end
  local sel = 1
  for k, un in ipairs(ports) do
    if un == ps.port then sel = k end
  end
  ps.port = ports[sel]
  if #ports > 0 then g.port_dd.selected_index = sel end
  g.port_hint.caption = #ports == 0 and {"rts-treasury.market-no-port"} or ""
  local contents = ps.port and market.port_contents(ps.port) or {}
  local can_buy = ps.port ~= nil and t.stage == 0
  -- goods
  for _, item in ipairs(market.items()) do
    local el = g.rows[item]
    if el and el.price.valid then
      local price, p0 = market.price(item), market.p0(item)
      el.price.caption = string.format("%.2f", price)
      el.price.style.font_color = price > p0 * 1.05 and GREEN or (price < p0 * 0.95 and RED or WHITE)
      local h = market.history(item)
      el.trend.caption = sparkline(h)
      el.trend.tooltip = {"rts-treasury.market-trend-tooltip", string.format("%.2f", p0), string.format("%.2f", h[1] or price),
                          string.format("%.2f", price)}
      el.port.caption = tostring(contents[item] or 0)
      local n = tonumber(el.amount.text) or 0
      el.sell.enabled = ps.port ~= nil and (contents[item] or 0) > 0
      el.buy.enabled = can_buy
      local qs = n > 0 and market.quote(item, math.min(n, contents[item] or 0), "sell")
      local qb = n > 0 and market.quote(item, n, "buy")
      el.sell.tooltip = {"rts-treasury.market-sell-tooltip", math.min(n, contents[item] or 0), "[item=" .. item .. "]",
                         cr(qs or 0)}
      el.buy.tooltip = can_buy and {"rts-treasury.market-buy-tooltip", n, "[item=" .. item .. "]", cr(qb or 0)}
        or {ps.port and "rts-treasury.market-buy-blocked" or "rts-treasury.market-no-port"}
    end
  end
  -- contracts and imports
  local parts = {""}
  local cs = market.contracts(f)
  for k = math.max(1, #cs - 5), #cs do parts[#parts + 1] = contract_line(f, cs[k]) end
  g.contracts.caption = #cs > 0 and parts or {"rts-treasury.market-no-contracts"}
  local ip = {""}
  for _, imp in ipairs(market.pending(f)) do
    if #ip < 7 then
      ip[#ip + 1] = {"", {"rts-treasury.market-import-line", imp.n, "[item=" .. imp.item .. "]",
        math.max(0, math.ceil((imp.due - game.tick) / 60))}, "  "}
    end
  end
  g.imports.caption = #ip > 1 and ip or ""
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local REASON = {cap = "rts-treasury.refused-cap", none = "rts-treasury.refused-none", deficit = "rts-treasury.refused-deficit",
                funds = "rts-treasury.refused-funds", ["no-port"] = "rts-treasury.refused-no-port",
                stock = "rts-treasury.refused-stock", item = "rts-treasury.refused-item"}

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local action = el.tags and el.tags.rts_market
  if not action then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  local ps = pstate(player.index)
  local f = player.force.name
  if action == "close" then
    marketgui.close(player)
  elseif action == "sell" or action == "buy" then
    local item = el.tags.item
    local row = ps.gui and ps.gui.rows[item]
    local n = row and tonumber(row.amount.text) or 0
    if action == "sell" then
      local got, why = market.sell(f, ps.port, item, n)
      util.log("market: player %d sells %d %s: %.1f cr %s", player.index, n, item, got, tostring(why or ""))
      if got <= 0 then player.print({REASON[why] or "rts-treasury.refused-none"}) end
    else
      local ok, r = market.buy(f, ps.port, item, n)
      util.log("market: player %d buys %d %s: %s %s", player.index, n, item, tostring(ok), tostring(r))
      if not ok then player.print({REASON[r] or "rts-treasury.refused-none"}) end
    end
    marketgui.refresh(player)
  end
end)

events.on(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.rts_market) then return end
  local player = game.get_player(e.player_index)
  local ps = pstate(e.player_index)
  if el.tags.rts_market == "tax" then
    local level = LEVELS[el.selected_index]
    if level then
      treasury.set_tax(player.force.name, level)
      util.log("market: player %d sets tax %s", player.index, level)
    end
  elseif el.tags.rts_market == "port" then
    local g = ps.gui
    ps.port = g and g.ports and g.ports[el.selected_index] or ps.port
  end
  marketgui.refresh(player)
end)

events.on(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and el.name == marketgui.FRAME then
    local player = game.get_player(e.player_index)
    if player then marketgui.close(player) end
  end
end)

events.on_nth_tick(marketgui.REFRESH, function()
  for _, player in pairs(game.connected_players) do
    local ps = util.pstorage(player.index).market_gui
    if ps and ps.gui then
      if visible_for(player) then marketgui.refresh(player) else marketgui.close(player) end
    end
  end
end)

return marketgui
