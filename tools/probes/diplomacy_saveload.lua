-- Phase 5 M2 diplomacy save/load probe (tools/saveload-check.sh with EXTRA_LUA, SAVE_MINUTE=3): before the save a war
-- goes on, a ceasefire proposal waits for its answer, an alliance stands and a tribute runs; after the load the answer
-- comes, the tribute goes on and every state is the same. Log "[rts] dsl ...".
local events = require("scripts.events")
local util = require("scripts.util")
local diplomacy = require("scripts.diplomacy")
local wars = require("scripts.wars")

local function states()
  local m = storage.match
  local parts = {}
  for _, a in ipairs(m.forces) do
    for _, b in ipairs(m.forces) do
      if a < b then parts[#parts + 1] = string.format("%s/%s=%s", a, b, diplomacy.state(a, b)) end
    end
  end
  return table.concat(parts, " ")
end

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = storage.dsl or {}
  storage.dsl = s
  local age = (e.tick - m.tick_started) / 60
  if age >= 100 and not s.a then
    s.a = true
    s.war = wars.declare("rts-ai-1", "rts-ai-2", {kind = "conquest"})
    diplomacy.set_state("rts-player", "rts-ai-3", "alliance", "dsl")
    local t = wars.declare("rts-ai-3", "rts-ai-1", {kind = "tribute"})
    wars.end_war(t, {kind = "tribute", payer = "rts-ai-1", payee = "rts-ai-3", cr_per_min = 10, minutes = 5})
    util.log("dsl: before: %s; war #%s; tributes %d", states(), tostring(s.war), #storage.war_meta.tributes)
  elseif age >= 170 and not s.b then
    s.b = true
    s.prop = diplomacy.propose("rts-ai-2", "rts-ai-1", "ceasefire", {})
    local P = diplomacy.get_proposal(s.prop)
    util.log("dsl: proposal #%s pending, answer at %.0f s", tostring(s.prop), P and P.answer_at and (P.answer_at - m.tick_started) / 60 or -1)
  elseif age >= 230 and not s.c then
    s.c = true
    local P = diplomacy.get_proposal(s.prop)
    local T = storage.war_meta.tributes[1]
    util.log("dsl: after: %s; proposal #%s %s (%s); tribute left %s; war #%s %s; relation ai-1>ai-2 %.1f", states(),
      tostring(s.prop), P and P.status or "missing", P and tostring(P.reason) or "-", T and T.left or "none",
      tostring(s.war), wars.get(s.war) and wars.get(s.war).status or "missing", diplomacy.relation("rts-ai-1", "rts-ai-2"))
  end
end)
