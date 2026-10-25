-- AI research (Phase 4: docs/PHASE4.md section 4 and 6; API in docs/qa/phase4-research-notes.md). Every PERIOD a
-- commander with a lab keeps one technology researching: the first one of its doctrine's order
-- (ai/doctrine.lua DEF[*].research, then the rest in tree order) that research.status calls "available" and whose
-- science kit the force can make (advanced kits need steel and copper). While the barracks are supply-capped
-- (C.capped, ai/mix.lua) Supply I/II go first, and a running non-supply technology is put back (its progress is
-- kept). C.science = {kit, want} tells the workshop factory (ai/commander.lua) which kit to keep in the network.
-- Counters: C.tech = {queued = n, done = {[tech] = tick}}; log lines "ai <force>: research <tech> (...)".
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local construction = require("scripts.ai.construction")
local doctrine = require("scripts.ai.doctrine")
local data = require("scripts.ai.orders_data")
local deps = require("scripts.ai.deps")

local tech = {}

tech.PERIOD = 5 * 60
tech.SUPPLY = {"rts-supply-1", "rts-supply-2"}
-- Phase 5 E1: in Nation mode these come before the doctrine's order (Industrialisation opens the Railway Charter)
tech.NATION_FIRST = {"rts-industrialisation"}
-- Phase 5 M2 ai: right after Industrialisation (Railways unlocks the Rail works now; first of all it took the aggressive
-- AI's labs for its opening techs and failed the 6-minute research check)
tech.NATION_NEXT = {"rts-railways"}
local ADVANCED = "rts-science-advanced"
local INDUSTRIAL = "rts-science-industrial"

local tiers -- [tech] = {kit, tier} from research.list(), built on first use (static prototype data)
local function info(name)
  if not tiers then
    tiers = {}
    -- every technology of both modes (Phase 5: the cache outlives a Skirmish match)
    for _, t in ipairs(deps.research.list_all and deps.research.list_all() or deps.research.list()) do
      tiers[t.name] = t
    end
  end
  return tiers[name]
end

-- The force can make the technology's kit: basic always; advanced needs steel and copper coming in.
-- Phase 5 M3 ai (Nation): an industrial kit also when its parts (engine, advanced circuit, sulfur) are at hand: the
-- planner makes them make targets and the market AI buys what the nation cannot make (ai/planner.lua)
tech.INDUSTRIAL_PARTS = {"engine-unit", "advanced-circuit", "sulfur"}
local function producible(C, name)
  local t = info(name)
  if not t then return false end
  -- Phase 5 E1: industrial kits come from the factory or a science campus only when their Age II parts exist
  if t.kit == INDUSTRIAL then
    -- (0.1.1, issue #1: not while Space Program stage 1 waits for the same parts, ai/planner.lua science_hold)
    if deps.planner and deps.planner.science_hold and deps.planner.science_hold(C) then return false end
    if construction.have(C, INDUSTRIAL) > 0 then return true end
    if not (deps.planner and deps.ages and deps.ages.is_nation()) then return false end
    for _, item in ipairs(tech.INDUSTRIAL_PARTS) do
      if construction.have(C, item) <= 0 and not construction.flowing(C, item) then return false end
    end
    return true
  end
  if t.kit ~= ADVANCED then return true end
  local function ok(item) return construction.have(C, item) > 0 or construction.flowing(C, item) end
  return ok("steel-plate") and ok("copper-plate")
end

--- The technology commander C researches next, or nil.
function tech.next(C)
  local research = deps.research
  local function try(name)
    return research.status(C.force, name) == "available" and producible(C, name)
  end
  if C.capped then
    for _, name in ipairs(tech.SUPPLY) do
      if try(name) then return name end
    end
  end
  if deps.ages and deps.ages.is_nation() then
    for _, name in ipairs(tech.NATION_FIRST) do
      if try(name) then return name end
    end
    if research.has(C.force, tech.NATION_FIRST[1]) then
      for _, name in ipairs(tech.NATION_NEXT) do
        if try(name) then return name end
      end
    end
    -- Phase 5 M3 ai: what the planner (Electrification in Age II, Geology) and the council (Fortification at war,
    -- Aviation, Air Force) want, in that order
    for _, name in ipairs(tech.wants(C)) do
      if try(name) then return name end
    end
  end
  for _, name in ipairs(doctrine.get(C.doctrine).research) do
    if try(name) then return name end
  end
  for _, t in ipairs(research.list()) do
    if try(t.name) then return t.name end
  end
  return nil
end

--- Phase 5 M3 ai (Nation): the technologies the planner and the council want first, in that order.
function tech.wants(C)
  local out = {}
  for _, name in ipairs(deps.council and deps.council.research_urgent and deps.council.research_urgent(C) or {}) do
    out[#out + 1] = name
  end
  for _, src in ipairs({deps.planner, deps.council}) do
    local list = src and src.research_want and src.research_want(C)
    for _, name in ipairs(list or {}) do out[#out + 1] = name end
  end
  return out
end

local function is_supply(name)
  return name == tech.SUPPLY[1] or name == tech.SUPPLY[2]
end

--- Number of rts technologies the force has researched.
function tech.done_count(force_name)
  local research = deps.research
  if not research then return 0 end
  local n = 0
  for _, t in ipairs(research.list()) do
    if research.has(force_name, t.name) then n = n + 1 end
  end
  return n
end

--- One research pass for commander C (every PERIOD ticks; commander.lua).
function tech.step(C)
  local research = deps.research
  if not research then return end
  C.tech = C.tech or {queued = 0, done = {}}
  local force = game.forces[C.force]
  if not force then return end
  local labs = buildings.count(C.force, "lab")
  -- completed technologies (for the log and the autotest)
  for _, t in ipairs(research.list()) do
    if not C.tech.done[t.name] and research.has(C.force, t.name) then
      C.tech.done[t.name] = game.tick
      util.log("ai %s: research %s done at %ds (%d done)", C.force, t.name, (game.tick - C.started) / 60,
        table_size(C.tech.done))
    end
  end
  if labs == 0 then
    C.science = nil
    return
  end
  local cur = force.current_research
  -- (0.1.1, issue #1) a running research with industrial kits is put back (its progress kept) while Space Program
  -- stage 1 waits for their parts (ai/planner.lua science_hold)
  if cur and deps.planner and deps.planner.science_hold and deps.planner.science_hold(C) then
    local t = info(cur.name)
    if t and t.kit == INDUSTRIAL then
      research.cancel(C.force, cur.name)
      util.log("ai %s: research %s put back: Space Program stage 1 waits for its advanced circuits and engines",
        C.force, cur.name)
      cur = force.current_research
    end
  end
  if cur and C.capped and not is_supply(cur.name) then
    -- supply first while capped: queue it, then put the running one back (it keeps its progress)
    for _, name in ipairs(tech.SUPPLY) do
      if research.status(C.force, name) == "available" and producible(C, name) then
        if research.queue(C.force, name) then
          research.cancel(C.force, cur.name)
          util.log("ai %s: research %s first (supply capped), %s put back", C.force, name, cur.name)
          cur = force.current_research
        end
        break
      end
    end
  end
  -- Phase 5 M3 ai (Nation): a wanted technology (tech.wants) takes the labs from a running one the AI does not want
  -- as much (its progress is kept): Electrification waited behind the doctrine's Age I list until minute 37
  if cur and not C.capped and deps.ages and deps.ages.is_nation() then
    local wants = tech.wants(C)
    local rank = #wants + 1
    for i, name in ipairs(wants) do
      if name == cur.name then
        rank = i -- the first place it is wanted at (Fortification is in the list twice at war)
        break
      end
    end
    for i = 1, rank - 1 do
      local name = wants[i]
      if research.status(C.force, name) == "available" and producible(C, name) then
        if research.queue(C.force, name) then
          research.cancel(C.force, cur.name)
          util.log("ai %s: research %s first (wanted), %s put back", C.force, name, cur.name)
          cur = force.current_research
        end
        break
      end
    end
  end
  if not cur then
    local name = tech.next(C)
    if name then
      local ok = research.queue(C.force, name)
      if ok then
        C.tech.queued = C.tech.queued + 1
        util.log("ai %s: research %s (%s doctrine, %d labs)", C.force, name, C.doctrine, labs)
      end
      cur = force.current_research
    end
  end
  if cur then
    local ing = cur.research_unit_ingredients[1]
    C.science = {kit = ing and ing.name or "rts-science-basic", want = labs * data.SCIENCE_PER_LAB, tech = cur.name}
  else
    C.science = nil
  end
end

return tech
