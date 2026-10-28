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

-- (0.1.3, issue #20) Industrialisation, then Railways: in Nation mode the first of them not researched yet takes the
-- labs from any other technology once its kit can be made (tech.step)
tech.PAIR = {[tech.NATION_FIRST[1]] = true, [tech.NATION_NEXT[1]] = true}
function tech.first_pair(C)
  local research = deps.research
  for _, name in ipairs({tech.NATION_FIRST[1], tech.NATION_NEXT[1]}) do
    if not research.has(C.force, name) then
      if research.status(C.force, name) == "available" and producible(C, name) then return name end
      return nil
    end
  end
  return nil
end

--- The technology commander C researches next, or nil.
function tech.next(C)
  local research = deps.research
  local function try(name)
    return research.status(C.force, name) == "available" and producible(C, name)
  end
  local nation = deps.ages and deps.ages.is_nation()
  -- (0.1.3, issue #20) Nation: Industrialisation, then Railways, before the supply cap's technologies once the
  -- opening's two are done (see tech.step)
  if nation and C.tech and table_size(C.tech.done) >= 2 then
    local first = tech.first_pair(C)
    if first then return first end
  end
  if C.capped then
    for _, name in ipairs(tech.SUPPLY) do
      if try(name) then return name end
    end
  end
  if nation then
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
  -- (0.1.3, issue #20) Nation: Industrialisation (the Railway Charter, then Age II) takes the labs from any running
  -- technology as soon as its kit can be made, the supply cap's included (their progress is kept). The aggressive AI
  -- researched Supply 2, Unlock Heavy or Mining 1 first and missed the Age II test deadline (about 20:00): M1 seed 501
  -- rts-ai-1 put Industrialisation back for Supply 2 at 11:00 and finished it at 21:20 (Age II 32:35, 0.1.2 release
  -- check); 801 ran Supply 2 from 7:00 to 14:05 first. Not before the opening's two technologies are done (the
  -- autotest's 6-minute research check: an economic AI's Unlock Heavy, put back at 4:30, left it at one). Railways
  -- (NATION_NEXT: the works factory's depot and crew kit recipes) right after it the same way: with Age II at 19:00
  -- the aggressive AI went to war at once and put Railways back for Aviation, and its first line's crew waited for
  -- kits from 22:00 to 36:00 (seed 801).
  local nation = deps.ages and deps.ages.is_nation()
  local first = nation and table_size(C.tech.done) >= 2 and tech.first_pair(C) or nil
  if cur and first and cur.name ~= first and research.queue(C.force, first) then
    research.cancel(C.force, cur.name)
    util.log("ai %s: research %s first (Nation), %s put back", C.force, first, cur.name)
    cur = force.current_research
  end
  local pair = nation and tech.PAIR[cur and cur.name or ""]
  if cur and C.capped and not is_supply(cur.name) and not pair then
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
  if cur and not C.capped and deps.ages and deps.ages.is_nation() and not tech.PAIR[cur.name] then
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
