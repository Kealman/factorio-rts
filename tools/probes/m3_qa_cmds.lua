-- Phase 5 M3 integration: two QA console shortcuts the M3 GUI protocol (docs/qa/phase5-m3-protocol.md) needs, written
-- for scripts/debug.lua's COMMANDS table (same helpers: admin_only, reply, command_force). Until they are merged, this
-- file registers them itself when it is required (a test copy: copy it into scripts/ and append
-- require("scripts.m3_qa_cmds") to control.lua), and a headless server runs a self-check once the match runs:
--   EXTRA_LUA=tools/probes/m3_qa_cmds.lua SEED=501 STOP_ON='m3qa check summary' tools/autotest-run.sh m3i-qacmds \
--     '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 300
--   /rts-front [force]   a town of the first rival (or <force>) 110-130 tiles east, west, south or north of your capital
--                        (the first free spot), its land next to yours; land and fronts refreshed at once (the fronts
--                        of a war: declare it in F4 first); the camera 24 tiles behind the new front (on the town
--                        without a war). Reply "rts-front: <force> town <id> at (x, y), <d> tiles <dir> of your
--                        capital; <fronts.describe>".
--   /rts-deposit <kind>  a 6x6 rare deposit (saltpetre, quartz, tungsten, diamonds, rare-earths, gold) on bare ground
--                        14-26 tiles from your capital, inside one of your logistic networks. Reply "rts-deposit: <kind>
--                        deposit (6x6) at (x, y), <d> tiles <dir> of your capital: place a Rare extractor on it".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local buildings = require("scripts.buildings")
local cities = require("scripts.cities")
local territory = require("scripts.territory")

local PLAYER = util.PLAYER_FORCE or "rts-player"
local function loaded_module(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/" .. string.gsub(name, "%.", "/") .. ".lua"] or l[name]
end
local function admin_only(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player and not player.admin then
    player.print("[rts] admins only")
    return false
  end
  return true
end
local function reply(cmd, line)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player then player.print(line) else game.print(line) end
  util.log("%s", line)
end
local function command_force(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  return player and player.force.name or PLAYER
end

local M = {}

-- ["rts-front"] = {help = ..., run = M.front}
M.front_help = "[force] - QA: found a town of the first rival (or <force>) 110-130 tiles from your capital, its land "
  .. "touching yours, and refresh land and fronts (declare the war in F4 for a front)"
function M.front(cmd)
  if not admin_only(cmd) then return end
  local F = command_force(cmd)
  local fronts, diplomacy = loaded_module("scripts.fronts"), loaded_module("scripts.diplomacy")
  local E = (cmd.parameter or ""):match("^%s*(%S+)")
  if not E then
    for _, f in ipairs(match.forces()) do
      if f ~= F and not E then E = f end
    end
  end
  local nation = storage.nations and storage.nations[F]
  local cap = nation and nation.capital and cities.get(nation.capital)
  local surface = match.surface()
  if not (cap and surface and E and game.forces[E] and E ~= F) then
    reply(cmd, "rts-front: needs a Nation match with a capital and a rival")
    return
  end
  local home = cap.position
  local spot, dir, dist
  for _, d in ipairs({115, 120, 110, 125, 130}) do
    for _, v in ipairs({{1, 0, "east"}, {-1, 0, "west"}, {0, 1, "south"}, {0, -1, "north"}}) do
      local p = {x = math.floor(home.x + v[1] * d) + 0.0, y = math.floor(home.y + v[2] * d) + 0.0}
      if not spot and surface.is_chunk_generated({math.floor(p.x / 32), math.floor(p.y / 32)})
          and territory.can_build(E, cities.CENTER, p)
          and surface.can_place_entity({name = cities.CENTER, position = p, force = E,
                                        build_check_type = defines.build_check_type.manual_ghost, forced = true}) then
        spot, dir, dist = p, v[3], d
      end
    end
  end
  if not spot then
    reply(cmd, "rts-front: no room for a town 110-130 tiles east, west, south or north of your capital")
    return
  end
  for _, e in ipairs(surface.find_entities_filtered({area = {{spot.x - 12, spot.y - 12}, {spot.x + 12, spot.y + 12}},
                                                    type = {"tree", "simple-entity", "cliff", "fish"}})) do
    if e.valid then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
  local id = cities.found(E, spot, {why = "(QA /rts-front)"})
  territory.flush()
  if fronts and fronts.flush then fronts.flush() end
  local at_war = diplomacy and diplomacy.state and diplomacy.state(F, E) == "war"
  -- the issuing player's camera 24 tiles behind the nearest segment (the front line 24 tiles towards the town), or on
  -- the town when there is no front yet
  local player = cmd.player_index and game.get_player(cmd.player_index)
  local camera = loaded_module("scripts.camera")
  if player and camera then
    local seg = fronts and fronts.nearest and fronts.nearest(F, spot, 400)
    local at = seg and seg.mid and seg.back and {x = seg.mid.x + seg.back.x * 24, y = seg.mid.y + seg.back.y * 24} or spot
    camera.jump_to(player, at)
  end
  reply(cmd, string.format("rts-front: %s town %s at %s, %d tiles %s of your capital; %s%s", E, tostring(id),
    util.pos_str(spot), dist, dir, fronts and fronts.describe and fronts.describe(F) or "no fronts",
    at_war and "" or " (no war: declare it in F4 to see the fronts)"))
end

-- ["rts-deposit"] = {help = ..., run = M.deposit}
M.deposit_help = "<kind> - QA: a 6x6 rare deposit (saltpetre, quartz, tungsten, diamonds, rare-earths, gold) on bare "
  .. "ground 14-26 tiles from your capital, inside your logistic network"
function M.deposit(cmd)
  if not admin_only(cmd) then return end
  local kind = (cmd.parameter or ""):match("^%s*(%S+)") or "saltpetre"
  local name = "rts-rare-" .. kind
  if not prototypes.entity[name] then
    reply(cmd, "rts-deposit: unknown kind " .. kind .. " (saltpetre, quartz, tungsten, diamonds, rare-earths, gold)")
    return
  end
  local F = command_force(cmd)
  local cc = buildings.main_cc(F)
  local surface = match.surface()
  if not (cc and cc.entity and cc.entity.valid and surface) then
    reply(cmd, "rts-deposit: no Command Center / capital")
    return
  end
  local home = cc.entity.position
  local function free(c)
    local area = {{c.x - 3, c.y - 3}, {c.x + 3, c.y + 3}}
    if surface.count_tiles_filtered({area = area, collision_mask = "water_tile"}) > 0 then return false end
    for _, e in ipairs(surface.find_entities_filtered({area = area})) do
      local t = e.type
      if t ~= "tree" and t ~= "simple-entity" and t ~= "fish" and t ~= "corpse" then return false end
    end
    return surface.find_logistic_network_by_position(c, F) ~= nil
  end
  local spot, dir, dist
  local dirs = {{1, -1, "north-east"}, {-1, 1, "south-west"}, {1, 1, "south-east"}, {-1, -1, "north-west"},
                {1, 0, "east"}, {0, -1, "north"}, {-1, 0, "west"}, {0, 1, "south"}}
  for _, d in ipairs({18, 22, 26, 14}) do
    for _, v in ipairs(dirs) do
      if not spot then
        local n = math.sqrt(v[1] * v[1] + v[2] * v[2])
        local c = {x = math.floor(home.x + v[1] / n * d) + 0.0, y = math.floor(home.y + v[2] / n * d) + 0.0}
        if free(c) then spot, dir, dist = c, v[3], d end
      end
    end
  end
  if not spot then
    reply(cmd, "rts-deposit: no bare 6x6 ground 14-26 tiles from your capital inside its network")
    return
  end
  for _, e in ipairs(surface.find_entities_filtered({area = {{spot.x - 3, spot.y - 3}, {spot.x + 3, spot.y + 3}},
                                                    type = {"tree", "simple-entity", "fish", "corpse"}})) do
    if e.valid then e.destroy() end
  end
  local n = 0
  for dx = -3, 2 do
    for dy = -3, 2 do
      if surface.create_entity({name = name, position = {spot.x + dx + 0.5, spot.y + dy + 0.5}, amount = 100}) then
        n = n + 1
      end
    end
  end
  reply(cmd, string.format("rts-deposit: %s deposit (6x6, %d tiles) at %s, %d tiles %s of your capital: place a Rare "
    .. "extractor on it", kind, n, util.pos_str(spot), dist, dir))
end

if not commands.commands["rts-front"] then commands.add_command("rts-front", M.front_help, M.front) end
if not commands.commands["rts-deposit"] then commands.add_command("rts-deposit", M.deposit_help, M.deposit) end

-- Self-check on a headless server (no player): both commands once the Nation match runs.
events.on_nth_tick(60, function()
  if #game.connected_players > 0 or not game.is_multiplayer() then return end
  local m = storage.match
  if not (m and m.phase == "running" and m.config and m.config.mode == "nation") then return end
  storage.m3qa = storage.m3qa or {at = game.tick + 600}
  local s = storage.m3qa
  if s.done or game.tick < s.at then return end
  s.done = true
  local diplomacy = loaded_module("scripts.diplomacy")
  local wars = loaded_module("scripts.wars")
  local E = match.ai_forces()[1]
  if wars and E and diplomacy.state(PLAYER, E) ~= "war" then wars.declare(PLAYER, E, {kind = "border"}) end
  M.front({parameter = ""})
  M.deposit({parameter = "saltpetre"})
  M.deposit({parameter = "gold"})
  M.deposit({parameter = "nonsense"})
  local fronts = loaded_module("scripts.fronts")
  local segs = fronts and fronts.segments(PLAYER) or {}
  local n = 0
  for _, e in ipairs(match.surface().find_entities_filtered({name = {"rts-rare-saltpetre", "rts-rare-gold"}})) do
    if util.distance(e.position, buildings.main_cc(PLAYER).entity.position) < 40 then n = n + 1 end
  end
  util.log("m3qa check summary: front segments %d, deposit tiles near the capital %d (%s)", #segs, n,
    (#segs > 0 and n == 72) and "PASS" or "FAIL")
end)

return M
