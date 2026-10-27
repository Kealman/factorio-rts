-- 0.1.3 (#37; docs/qa/release-0-1-3-r4-rails-notes.md): the vanilla rail planner for RTS players. Nation mode only.
--
-- The Rail button of the build menu (Economy tab, Railways) puts a "rail" ghost in the cursor like any build item
-- (hud.lua -> cursor.give_ghost); while it is there camera.lua turns hover selection on, which the 2.x planner needs to
-- start from the rail end under the pointer (notes section 1). The player lays track as in the vanilla remote view: a
-- click on the end of a rail (or of the rail a first click places), then a click where the track goes (the path follows
-- the pointer; a drag only moves it); curves, diagonals, joins and junctions are the planner's; R turns the first rail;
-- the first Q stops the path, the second one (or a right click) ends laying. Another
-- nation's land refuses the pieces on it with the territory message (territory.lua's build check); the remote view
-- itself builds nothing on uncharted ground.
--
-- This module collects the rail ghosts the players of a force place and, FLUSH_TICKS after the force's last one, hands
-- them to rails.adopt_ghosts: chains of planner track that robots in range and construction crews build (rails.lua).
-- On the first load of a 0.1.2 save it turns the unfinished Rail tool segments into planner track the same way (their
-- ghosts stay) and removes what is left of the Rail tool (storage.railtool, its panel). The Rail tool itself is gone.
--
-- Owns storage.railplan = {pending = {[force] = {surface = index, ghosts = {LuaEntity}, last = tick}}, migrated = true}.
-- API: railplan.flush(force_name) -> lines made (fixtures), railplan.adopt(force_name, surface, ghosts) -> lines made.
-- Log lines "[rts] railplan: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local rails = require("scripts.rails")

local railplan = {}
railplan.FLUSH_TICKS = 60 -- a planner drag places its pieces over a few ticks; they are adopted together

local function S()
  storage.railplan = storage.railplan or {}
  local s = storage.railplan
  s.pending = s.pending or {}
  return s
end

local function sorted_keys(t)
  local list = {}
  for k in pairs(t) do list[#list + 1] = k end
  table.sort(list)
  return list
end

--- Adopt rail ghosts as planner track now (rails.adopt_ghosts). Returns the number of track lines made.
function railplan.adopt(force_name, surface, ghosts)
  local n = rails.adopt_ghosts(force_name, surface, ghosts)
  util.log("railplan: %d rail ghosts of %s on %s handed over: %d track lines", #ghosts, force_name, surface.name, n)
  return n
end

--- Hand a force's pending rail ghosts over at once. Returns the number of track lines made.
function railplan.flush(force_name)
  local s = S()
  local P = s.pending[force_name]
  s.pending[force_name] = nil
  local surface = P and game.surfaces[P.surface]
  if not surface then return 0 end
  return railplan.adopt(force_name, surface, P.ghosts)
end

-- A player's rail ghost (the planner's, or a single one): pending for its force. Robots or a crew of an older line may
-- build it before the flush; rails.adopt_ghosts skips what is no longer a ghost.
events.on(defines.events.on_built_entity, function(e)
  local entity = e.entity
  if not (entity and entity.valid and entity.type == "entity-ghost" and rails.GROUND_SET[entity.ghost_name]) then
    return
  end
  if not ((e.player_index or 0) > 0 and rails.nation()) then return end
  local force_name = entity.force.name
  if not rails.human(force_name) then return end
  local s = S()
  local P = s.pending[force_name]
  if P and P.surface ~= entity.surface.index then
    railplan.flush(force_name)
    P = nil
  end
  if not P then
    P = {surface = entity.surface.index, ghosts = {}}
    s.pending[force_name] = P
  end
  P.ghosts[#P.ghosts + 1] = entity
  P.last = game.tick
end)

events.on_nth_tick(30, function()
  local s = storage.railplan
  if not (s and s.pending and next(s.pending)) then return end
  for _, force_name in ipairs(sorted_keys(s.pending)) do
    if game.tick - (s.pending[force_name].last or 0) >= railplan.FLUSH_TICKS then railplan.flush(force_name) end
  end
end)

function railplan.init()
  local s = S()
  -- 0.1.2's Rail tool: its state and an open panel go (the tool is replaced by the planner)
  if storage.railtool then
    storage.railtool = nil
    util.log("railplan: the 0.1.2 Rail tool state removed")
  end
  for _, player in pairs(game.players) do
    local frame = player.gui.screen.rts_railtool_frame
    if frame and frame.valid then
      frame.destroy()
      util.log("railplan: the Rail tool panel of player %d closed", player.index)
    end
  end
  if not s.migrated then
    s.migrated = true
    local n, made, ghosts = rails.segments_to_planner()
    if n > 0 then
      util.log("railplan: %d Rail tool segments not built yet became planner track: %d ghosts kept, %d track lines", n,
        ghosts, made)
    end
  end
end

return railplan
