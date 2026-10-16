-- Orders for selected units (docs/PHASE1.md "Orders"): move, attack, attack-move, stop, hold, the
-- right-click input handlers, and attack-move re-targeting.
-- Deviation from PHASE1, measured in the headless autotest: "attack" uses attack_area on the target instead
-- of defines.command.attack (see ATTACK_MODE), and both attack orders treat a completion as "keep going"
-- (renew the attack while the target lives / resume the attack-move leg) because distractions end them early.
--
-- Owns, for the units it commands, these storage.units[n] fields:
--   order   "move" | "attack" | "attack_move" | "hold" while orders.lua drives the unit, "idle" when it lets go
--   dest    MapPosition?   formation slot of a move / attack-move, hold point of a hold
--   target  LuaEntity?     attack target, or the enemy an attack-move was re-targeted at
--   issuer  "orders"       set together with order; on_ai_command_completed is handled only for these units
--   fails   number?        consecutive failed attack / attack-move commands (gives up after MAX_FAILS)
-- Claim rule (units.lua): a record whose order is not "idle" and whose issuer is not "orders" belongs to
-- another module (debug.lua's "autotest", match.lua's enemy waves) and is never commanded from here.
--
-- And storage.orders:
--   armed      {[player_index] = tick}   attack-move armed by F: the next plain right click is an attack-move
--   rclick     {[player_index] = {tick, position, entity?, wait}}   pending right-click fallback
--   area_tick  {[player_index] = tick}   tick of the last reverse-select event handled
--   cancel_tick {[player_index] = tick}  tick a right click ended build mode (Phase 2)
--   stats      counters for the autotest and /rts-dump
--
-- Right click (spike decision 10): the rts-cursor tool turns a right click or drag into
-- on_player_reverse_selected_area (shift: on_player_alt_reverse_selected_area). That event is the primary
-- path. The rts-rclick custom input fires on button press, before the area event, which only comes on
-- release (the spike log shows them ~50 ms = ~3 ticks apart for a quick click). So rts-rclick only parks a
-- pending fallback; any reverse-select event for that player cancels it. The fallback runs when no area
-- event came: 1 tick later if the cursor did not hold the tool (no area event can come), RCLICK_WAIT_TOOL
-- ticks later if it did (a drag longer than that gets the fallback order first and the area order on release).
--
-- Phase 2:
-- * Rally point: a plain right click while an own barracks is selected (no units) sets its rally point
--   (buildings.set_rally); the flag is drawn by selection.lua. QA log line "rally set barracks #N -> (x, y) ...".
-- * Build mode: a right click while a ghost is in the cursor ends build mode (the RTS cursor comes back) and
--   orders nothing; a reverse-select click right after it is ignored (storage.orders.cancel_tick).
-- * The armed attack-move prompt is shown on the HUD's top strip (hud.lua reads orders.is_armed), not as
--   flying text at the cursor.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local selection = require("scripts.selection")
local buildings = require("scripts.buildings")
local cursor = require("scripts.cursor")

local orders = {}

orders.ISSUER = "orders"

local SPACING = 2.5             -- minimum formation spacing in tiles
local SPACING_MARGIN = 0.75     -- added to the widest collision box in the formation
local MOVE_RADIUS = 1           -- go_to_location radius
local ATTACK_MOVE_RADIUS = 8    -- attack_area radius
local RETARGET_RANGE = 30       -- tiles searched for the next enemy when an attack-move completes
local MAX_FAILS = 3             -- consecutive failed commands before an attack / attack-move unit is stopped
-- Attacking one entity. defines.command.attack on a spider-unit completes (result=success) on nearly every
-- tick while the target is alive, so the order has to be re-issued constantly and the units re-aim each time:
-- in the autotest 6 walkers needed ~16 s and ~5000 completion events to kill one 200 hp walker (7-9 s with
-- distraction none). attack_area centred on the target, re-issued at the target's current position when it
-- completes, killed it in ~8 s with 14 completions. distraction none with attack_area never closed in.
local ATTACK_MODE = "area"      -- "area" (attack_area on the target) or "attack" (defines.command.attack)
local ATTACK_DISTRACTION = defines.distraction.by_enemy
local ATTACK_AREA_RADIUS = 4
local FEEDBACK_TTL = 20         -- ticks an order marker stays on screen (brief, but large: see feedback())
local FEEDBACK_RADIUS = 1.75    -- tiles; ring at a ground target
local FEEDBACK_ENTITY_PAD = 0.5 -- tiles added to an entity target's selection box half-diagonal
local FEEDBACK_WIDTH = 4        -- pixels
local FEEDBACK_DOT = 0.3        -- tiles; filled centre dot, marks the exact point
local RCLICK_WAIT_TOOL = 120    -- ticks to wait for the area event when the cursor held the rts-cursor
local CANCEL_IGNORE_TICKS = 20  -- a reverse-select this soon after a right click ended build mode is that click's
                                -- release (~3 ticks for a quick click), not a new order; ignored
local COLORS = {
  move = {r = 0.2, g = 1, b = 0.2, a = 1},
  attack = {r = 1, g = 0.2, b = 0.15, a = 1},
  attack_move = {r = 1, g = 0.75, b = 0.1, a = 1},
}

local CMD, DISTRACTION = defines.command, defines.distraction

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function ostate()
  local o = storage.orders
  if not o then
    o = {}
    storage.orders = o
  end
  o.armed = o.armed or {}
  o.rclick = o.rclick or {}
  o.area_tick = o.area_tick or {}
  o.cancel_tick = o.cancel_tick or {}
  o.stats = o.stats or {issued = {}, completed = {}, retargets = 0, released = 0, fallbacks = 0, area_orders = 0}
  return o
end

local function bump(tbl, key, n)
  tbl[key] = (tbl[key] or 0) + (n or 1)
end

--- Counters: issued[order], completed[order], retargets, resumed, swept, released, fallbacks, area_orders.
function orders.stats()
  return ostate().stats
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function pos_of(p)
  local x, y = util.xy(p)
  return {x = x, y = y}
end

-- Unit records an order may command: `who` is a player index (that player's selection) or an array of
-- LuaEntity. Units claimed by another module are skipped.
local function resolve(who)
  local list = type(who) == "number" and selection.get(who) or who
  local out = {}
  for _, entity in pairs(list) do
    if entity.valid and entity.unit_number then
      local rec = units.get(entity.unit_number)
      if rec and (rec.order == units.IDLE or rec.issuer == orders.ISSUER) then out[#out + 1] = rec end
    end
  end
  return out
end

-- Size of the box a formation slot must hold for this prototype (widest side of the collision box).
local function unit_width(entity)
  local box = entity.prototype.collision_box
  return math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y)
end

--- Formation spacing for a set of unit records.
function orders.spacing(recs)
  local widest = 0
  for _, rec in pairs(recs) do widest = math.max(widest, unit_width(rec.entity)) end
  return math.max(SPACING, widest + SPACING_MARGIN)
end

--- Formation slots around `center`, one per record (same indices): a grid of ceil(sqrt(n)) columns facing
--- the direction of travel. Units are matched to slots by sorting both front-to-back and then left-to-right,
--- so paths do not cross much.
function orders.formation(recs, center)
  local n = #recs
  if n == 0 then return {} end
  if n == 1 then return {{x = center.x, y = center.y}} end
  local from = util.centroid((function()
    local l = {}
    for i, rec in ipairs(recs) do l[i] = rec.entity end
    return l
  end)())
  local dx, dy = center.x - from.x, center.y - from.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.5 then dx, dy = 1, 0 else dx, dy = dx / len, dy / len end
  local px, py = -dy, dx -- perpendicular to the direction of travel

  local along, across, idx = {}, {}, {}
  for i, rec in ipairs(recs) do
    local x, y = util.xy(rec.entity)
    along[i], across[i], idx[i] = x * dx + y * dy, x * px + y * py, i
  end
  table.sort(idx, function(a, b)
    if along[a] ~= along[b] then return along[a] > along[b] end
    return a < b
  end)

  local spacing = orders.spacing(recs)
  local cols = math.ceil(math.sqrt(n))
  local rows = math.ceil(n / cols)
  local slots, k = {}, 1
  for r = 0, rows - 1 do
    local in_row = math.min(cols, n - r * cols)
    local row = {}
    for c = 1, in_row do
      row[c] = idx[k]
      k = k + 1
    end
    table.sort(row, function(a, b)
      if across[a] ~= across[b] then return across[a] < across[b] end
      return a < b
    end)
    local fwd = ((rows - 1) / 2 - r) * spacing -- row 0 is the front row
    for c, i in ipairs(row) do
      local side = (c - 1 - (in_row - 1) / 2) * spacing
      slots[i] = {x = center.x + dx * fwd + px * side, y = center.y + dy * fwd + py * side}
    end
  end
  return slots
end

local function claim(rec, order, dest, target)
  rec.order, rec.dest, rec.target, rec.issuer, rec.fails = order, dest, target, orders.ISSUER, nil
end

-- The order is over: the unit goes back to idle with `stop` (spike decision 3: never leave it commandless).
local function release(rec)
  rec.order, rec.dest, rec.target, rec.issuer, rec.fails = units.IDLE, nil, nil, nil, nil
  units.stop(rec.entity)
  ostate().stats.released = ostate().stats.released + 1
end

local function command(rec, cmd)
  local c = rec.entity.commandable
  if not c then return false end
  c.set_command(cmd)
  return true
end

-- The command that attacks one target entity (see ATTACK_MODE).
local function attack_command(target)
  if ATTACK_MODE == "area" then
    return {type = CMD.attack_area, destination = target.position, radius = ATTACK_AREA_RADIUS,
            distraction = ATTACK_DISTRACTION}
  end
  return {type = CMD.attack, target = target, distraction = ATTACK_DISTRACTION}
end

-- Brief marker at the order's destination (or on the attacked entity), shown to the ordering player only.
-- For the fake autotest index the marker is created invisible, so the call is still exercised.
local function feedback(who, target, color, surface)
  if type(who) ~= "number" then return end
  local player = selection.real_player(who)
  local is_entity = type(target) == "table" and target.object_name == "LuaEntity"
  local radius = FEEDBACK_RADIUS
  if is_entity and target.valid then
    local box = target.selection_box
    local w, h = box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y
    radius = math.max(FEEDBACK_RADIUS, math.sqrt(w * w + h * h) / 2 + FEEDBACK_ENTITY_PAD)
  end
  local players, visible = player and {who} or nil, player ~= nil
  rendering.draw_circle({color = color, radius = radius, width = FEEDBACK_WIDTH, filled = false, target = target,
    surface = surface, time_to_live = FEEDBACK_TTL, players = players, visible = visible})
  if not is_entity then
    rendering.draw_circle({color = color, radius = FEEDBACK_DOT, filled = true, target = target, surface = surface,
      time_to_live = FEEDBACK_TTL, players = players, visible = visible})
  end
end

local function disarm(player_index, why)
  if type(player_index) ~= "number" then return false end
  local armed = ostate().armed
  if not armed[player_index] then return false end
  armed[player_index] = nil
  util.log("attack-move disarmed player=%d (%s)", player_index, why)
  selection.notify_hud(player_index)
  return true
end

-- QA log line for an order given to a player's selection: "order <name> n=<units> ... player=<index>".
-- Orders given to an entity list (scripts) are not logged.
local function log_order(who, name, n, detail)
  if type(who) ~= "number" then return end
  util.log("order %s n=%d %splayer=%d", name, n, detail and (detail .. " ") or "", who)
end

---------------------------------------------------------------------------
-- Orders. `who` is a player index (acts on that player's selection) or an array of LuaEntity.
-- Each returns the number of units that got the order.
---------------------------------------------------------------------------

--- Move to `position` in formation, ignoring enemies on the way (go_to_location, distraction none).
function orders.move(who, position)
  local recs = resolve(who)
  if #recs == 0 then
    log_order(who, "move", 0, "dest=" .. util.pos_str(position))
    return 0
  end
  local center = pos_of(position)
  local slots = orders.formation(recs, center)
  for i, rec in ipairs(recs) do
    claim(rec, "move", slots[i])
    command(rec, {type = CMD.go_to_location, destination = slots[i], radius = MOVE_RADIUS,
                  distraction = DISTRACTION.none})
  end
  bump(ostate().stats.issued, "move", #recs)
  log_order(who, "move", #recs, string.format("dest=%s spacing=%.2f", util.pos_str(center), orders.spacing(recs)))
  feedback(who, center, COLORS.move, recs[1].entity.surface)
  return #recs
end

--- Attack one entity (distraction by_enemy; see ATTACK_MODE for the command used). The order is renewed
--- at the target's position whenever it completes and ends (units idle with stop) when the target is gone.
function orders.attack(who, target)
  if not (target and target.valid) then return 0 end
  local recs = resolve(who)
  local detail = string.format("target=#%s %s (%s) at %s", tostring(target.unit_number), target.name,
    target.force.name, util.pos_str(target.position))
  if #recs == 0 then
    log_order(who, "attack", 0, detail)
    return 0
  end
  for _, rec in ipairs(recs) do
    claim(rec, "attack", nil, target)
    command(rec, attack_command(target))
  end
  bump(ostate().stats.issued, "attack", #recs)
  log_order(who, "attack", #recs, detail)
  feedback(who, target, COLORS.attack, target.surface)
  return #recs
end

--- Attack-move to `position` in formation (attack_area radius 8, distraction by_anything). A distraction
--- ends attack_area early (result=success), so a unit that completes more than the radius away from its
--- slot resumes towards it; one that arrived re-targets the nearest enemy within RETARGET_RANGE, or stops.
function orders.attack_move(who, position)
  local recs = resolve(who)
  if #recs == 0 then
    log_order(who, "attack-move", 0, "dest=" .. util.pos_str(position))
    return 0
  end
  local center = pos_of(position)
  local slots = orders.formation(recs, center)
  for i, rec in ipairs(recs) do
    claim(rec, "attack_move", slots[i])
    command(rec, {type = CMD.attack_area, destination = slots[i], radius = ATTACK_MOVE_RADIUS,
                  distraction = DISTRACTION.by_anything})
  end
  bump(ostate().stats.issued, "attack_move", #recs)
  log_order(who, "attack-move", #recs, "dest=" .. util.pos_str(center))
  feedback(who, center, COLORS.attack_move, recs[1].entity.surface)
  return #recs
end

--- Stop: drop the order and stand still (stop still returns fire). Also cancels an armed attack-move.
function orders.stop(who)
  disarm(who, "stop")
  local recs = resolve(who)
  for _, rec in ipairs(recs) do release(rec) end
  bump(ostate().stats.issued, "stop", #recs)
  log_order(who, "stop", #recs)
  return #recs
end

--- Hold position: stop, and stay claimed as "hold" so the unit is re-stopped whenever its command ends.
function orders.hold(who)
  disarm(who, "hold")
  local recs = resolve(who)
  for _, rec in ipairs(recs) do
    claim(rec, "hold", pos_of(rec.entity.position))
    units.stop(rec.entity)
  end
  bump(ostate().stats.issued, "hold", #recs)
  log_order(who, "hold", #recs)
  return #recs
end

-- Re-issue the current attack-move leg towards rec.dest (it was cut short by a distraction).
local function resume_attack_move(rec)
  command(rec, {type = CMD.attack_area, destination = rec.dest, radius = ATTACK_MOVE_RADIUS,
                distraction = DISTRACTION.by_anything})
  local stats = ostate().stats
  stats.resumed = (stats.resumed or 0) + 1
end

-- Next leg of an attack-move: the nearest enemy within RETARGET_RANGE, else stop.
local function retarget(rec)
  local entity = rec.entity
  local enemy = entity.surface.find_nearest_enemy({position = entity.position, max_distance = RETARGET_RANGE,
                                                   force = entity.force})
  if not enemy then
    release(rec)
    return false
  end
  rec.target, rec.dest = enemy, pos_of(enemy.position)
  command(rec, {type = CMD.attack_area, destination = rec.dest, radius = ATTACK_MOVE_RADIUS,
                distraction = DISTRACTION.by_anything})
  local stats = ostate().stats
  stats.retargets = stats.retargets + 1
  return true
end

---------------------------------------------------------------------------
-- Attack-move arming (F) and right-click handling
---------------------------------------------------------------------------

--- Why a player may not order now (Phase 4 QA): the match ended, or the player's side is out of it. Returns a locale
--- key or nil. The autotest's fake player index 0 is never locked.
function orders.locked_reason(player_index)
  if type(player_index) ~= "number" or player_index == 0 then return nil end
  local m = storage.match
  if not m then return nil end
  if m.phase == "ended" then return "rts.orders-match-over" end
  if m.phase == "running" and m.out and m.out[selection.force_name(player_index)] then return "rts.orders-out" end
  return nil
end

local function refuse_locked(player_index, what)
  local key = orders.locked_reason(player_index)
  if not key then return false end
  local player = game.get_player(player_index)
  if player then player.create_local_flying_text({text = {key}, create_at_cursor = true}) end
  util.log("orders: %s refused player=%d (%s)", what, player_index, key)
  return true
end

--- Arm (on = true), disarm (false) or toggle (nil) attack-move for a player: the next plain right click
--- becomes an attack-move. Returns the new state.
function orders.arm_attack_move(player_index, on)
  local armed = ostate().armed
  if on == nil then on = armed[player_index] == nil end
  if on and refuse_locked(player_index, "attack-move") then
    armed[player_index] = nil
    selection.notify_hud(player_index)
    return false
  end
  armed[player_index] = on and game.tick or nil
  util.log("attack-move %s player=%d", on and "armed" or "disarmed (toggle)", player_index)
  -- The prompt is the HUD's top-strip message line while armed (Phase 1 QA follow-up 5).
  selection.notify_hud(player_index)
  return on
end

--- True while the player's next right click is an attack-move.
function orders.is_armed(player_index)
  return ostate().armed[player_index] ~= nil
end

-- Pick the enemy entity a right click meant: a registered RTS unit if any, then the one nearest the centre.
local function pick_enemy(force, entities, center)
  local best, best_d, best_unit
  for _, e in pairs(entities) do
    if e.valid and e.force and force.is_enemy(e.force) then
      local is_unit = e.unit_number ~= nil and units.get(e.unit_number) ~= nil
      local d = util.distance_sq(e, center)
      if not best or (is_unit and not best_unit) or (is_unit == best_unit and d < best_d) then
        best, best_d, best_unit = e, d, is_unit
      end
    end
  end
  return best
end

--- Set the rally point of the player's selected barracks to `position` (Phase 2). Returns "rally" and 1 when
--- it was set, "none" and 0 when no barracks is selected. QA log line: "rally set barracks #N -> (x, y) ok=...".
function orders.set_rally(player_index, position)
  local un, rec = selection.get_building(player_index)
  if not rec then return "none", 0 end
  if rec.kind ~= "barracks" then
    util.log("rally ignored: the selected %s #%d has no rally point player=%d", rec.kind, un, player_index)
    return "none", 0
  end
  local pos = pos_of(position)
  local ok = buildings.set_rally(un, pos)
  util.log("rally set barracks #%d -> %s ok=%s player=%d", un, util.pos_str(pos), tostring(ok), player_index)
  selection.refresh_building(player_index)
  feedback(player_index, pos, COLORS.move, rec.entity.surface)
  return "rally", ok and 1 or 0
end

-- What a plain right click at `position` means: with a building selected (and no units) the rally point,
-- else attack-move when armed, attack when it hit an enemy, otherwise move. Returns the order name and the
-- number of units (or buildings) ordered.
-- Phase 4 hooks (logistics.lua: haulers take route orders). fn(player_index, position, entities, alt) returns an
-- order name and a count when it consumed the right click, or nil to let the decision below run. Load time only.
-- `first` puts the hook ahead of the others: abilities.lua's armed targeted ability (scanner sweep, artillery strike)
-- takes the next right click before the hauler and Commander hooks see it, like an armed attack-move.
local right_click_hooks = {}
function orders.on_right_click(fn, first)
  if first then table.insert(right_click_hooks, 1, fn) else right_click_hooks[#right_click_hooks + 1] = fn end
end
local function run_right_click_hooks(player_index, position, entities, alt)
  for i = 1, #right_click_hooks do
    local order, n = right_click_hooks[i](player_index, position, entities, alt)
    if order then return order, n end
  end
end

local function right_click_order(player_index, position, entities)
  local hooked, hooked_n = run_right_click_hooks(player_index, position, entities, false)
  if hooked then return hooked, hooked_n end
  if selection.count(player_index) == 0 and selection.get_building(player_index) then
    disarm(player_index, "a building is selected")
    return orders.set_rally(player_index, position)
  end
  if disarm(player_index, "used by this right click") then return "attack_move", orders.attack_move(player_index, position) end
  local force = game.forces[selection.force_name(player_index)]
  local enemy = pick_enemy(force, entities, position)
  if enemy then return "attack", orders.attack(player_index, enemy) end
  return "move", orders.move(player_index, position)
end

--- Reverse-select area from the rts-cursor (right click / drag; alt = shift, attack-move).
--- Cancels any pending rts-rclick fallback for the player. Returns the order name and unit count.
function orders.handle_reverse_area(player_index, entities, area, alt)
  local o = ostate()
  o.area_tick[player_index] = game.tick
  o.rclick[player_index] = nil
  local lt, rb = area.left_top, area.right_bottom
  local center = {x = (lt.x + rb.x) / 2, y = (lt.y + rb.y) / 2}
  local cancelled = o.cancel_tick[player_index]
  if cancelled and game.tick - cancelled <= CANCEL_IGNORE_TICKS then
    o.cancel_tick[player_index] = nil
    util.log("orders: reverse-select at %s ignored: that right click ended build mode player=%d",
      util.pos_str(center), player_index)
    return "none", 0
  end
  o.stats.area_orders = o.stats.area_orders + 1
  if refuse_locked(player_index, "right click") then return "none", 0 end
  if alt then
    local hooked, hooked_n = run_right_click_hooks(player_index, center, entities, true)
    if hooked then return hooked, hooked_n end
    disarm(player_index, "shift + right click")
    return "attack_move", orders.attack_move(player_index, center)
  end
  return right_click_order(player_index, center, entities)
end

--- rts-rclick custom input (button press). Parks a fallback that runs only if no reverse-select event
--- arrives for the player (see the header). `holds_tool`: the cursor held the rts-cursor at the press.
function orders.handle_rclick(player_index, position, hovered, holds_tool, in_gui)
  if in_gui then return false end -- clicks on the HUD belong to hud.lua
  local o = ostate()
  if o.area_tick[player_index] == game.tick then return false end -- the area event of this tick came first
  o.rclick[player_index] = {tick = game.tick, position = pos_of(position),
                            entity = (hovered and hovered.valid) and hovered or nil,
                            wait = holds_tool and RCLICK_WAIT_TOOL or 1}
  return true
end

local function run_fallback(player_index, pending)
  if refuse_locked(player_index, "right click") then return end
  local stats = ostate().stats
  stats.fallbacks = stats.fallbacks + 1
  local entities = (pending.entity and pending.entity.valid) and {pending.entity} or {}
  local order, n = right_click_order(player_index, pending.position, entities)
  util.log("orders: player %d right click at %s without a reverse-select event -> fallback %s for %d units",
    player_index, util.pos_str(pending.position), order, n)
end

events.on(defines.events.on_tick, function(e)
  local o = storage.orders
  local pending = o and o.rclick
  if not pending or next(pending) == nil then return end
  for index, p in pairs(pending) do
    if e.tick - p.tick >= p.wait then
      pending[index] = nil
      run_fallback(index, p)
    end
  end
end)

local holds_tool = cursor.holds_tool

events.on(defines.events.on_player_reverse_selected_area, function(e)
  if e.item ~= util.CURSOR_ITEM then return end
  orders.handle_reverse_area(e.player_index, e.entities, e.area, false)
end)

events.on(defines.events.on_player_alt_reverse_selected_area, function(e)
  if e.item ~= util.CURSOR_ITEM then return end
  orders.handle_reverse_area(e.player_index, e.entities, e.area, true)
end)

events.on("rts-rclick", function(e)
  local player = game.get_player(e.player_index)
  if not player then return end
  -- Build mode (a ghost from the build menu in the cursor): the right click only ends it.
  local ghost = not e.in_gui and cursor.ghost_name(player)
  if ghost then
    ostate().cancel_tick[e.player_index] = game.tick
    cursor.ensure(player, true, "right click ends build mode")
    util.log("build mode ended item=%s player=%d (right click)", ghost, e.player_index)
    return
  end
  orders.handle_rclick(e.player_index, e.cursor_position, player.selected, holds_tool(player), e.in_gui)
end)

events.on("rts-attack-move", function(e) orders.arm_attack_move(e.player_index) end)
events.on("rts-stop", function(e) orders.stop(e.player_index) end)
events.on("rts-hold", function(e) orders.hold(e.player_index) end)

---------------------------------------------------------------------------
-- Completion: only units this module claimed (issuer == "orders"). units.lua's handler runs first and
-- ignores them because their order is not "idle".
---------------------------------------------------------------------------
events.on(defines.events.on_ai_command_completed, function(e)
  local rec = storage.units[e.unit_number]
  if not (rec and rec.issuer == orders.ISSUER and rec.entity.valid) then return end
  local order = rec.order
  bump(ostate().stats.completed, order)
  if order == "move" then
    release(rec)
    return
  elseif order == "hold" then
    units.stop(rec.entity)
    return
  end
  -- attack / attack_move: distractions end these commands early with result=success (seen in the autotest),
  -- so completion alone does not mean the job is done.
  if e.result == defines.behavior_result.fail then
    rec.fails = (rec.fails or 0) + 1
    if rec.fails >= MAX_FAILS then
      release(rec)
      return
    end
  else
    rec.fails = nil
  end
  if order == "attack" then
    local target = rec.target
    if target and target.valid then
      command(rec, attack_command(target))
    else
      -- QA log line: the attack is over because the target died ("order attack done unit=#N (target gone)")
      util.log("order attack done unit=#%d (target gone)", rec.entity.unit_number)
      release(rec)
    end
  elseif order == "attack_move" then
    if rec.dest and util.distance(rec.entity, rec.dest) > ATTACK_MOVE_RADIUS then
      resume_attack_move(rec)
    else
      retarget(rec)
    end
  end
end)

-- attack_area does not complete while the unit stands in an empty area at its destination, so an
-- attack-move whose unit arrived and has no enemy within RETARGET_RANGE would stay "attack_move" forever,
-- and an attack whose target died may never report completion either. Sweep every 2 s and stop those
-- units (the "else stop" of the attack-move rule; "target gone" for attack).
local SWEEP_TICKS = 120
local function done_waiting(rec)
  local entity = rec.entity
  if rec.order == "attack" then return not (rec.target and rec.target.valid) end
  if rec.order ~= "attack_move" or not rec.dest or util.distance(entity, rec.dest) > ATTACK_MOVE_RADIUS then
    return false
  end
  return entity.surface.find_nearest_enemy({position = entity.position, max_distance = RETARGET_RANGE,
                                            force = entity.force}) == nil
end

events.on_nth_tick(SWEEP_TICKS, function()
  if not storage.units then return end
  for _, rec in pairs(storage.units) do
    if rec.issuer == orders.ISSUER and rec.entity.valid and done_waiting(rec) then
      if rec.order == "attack" then util.log("order attack done unit=#%d (target gone)", rec.entity.unit_number) end
      release(rec)
      local stats = ostate().stats
      stats.swept = (stats.swept or 0) + 1
    end
  end
end)

function orders.init()
  ostate()
end

--- Forget armed attack-moves and pending right clicks of every player (used by /rts-qa-reset).
function orders.reset()
  local o = ostate()
  for index in pairs(o.armed) do disarm(index, "reset") end
  o.rclick = {}
end

return orders
