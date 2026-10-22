-- Phase 5 M3 ai (QA fix diagnosis): every minute, the state of each AI force's barracks (test copy only; pass it as
-- EXTRA_LUA with tools/probes/m1_acceptance.lua's runs replaced by this one, or chain it). Logs:
--   [rts] ai3 barracks diag t<tick> <force> #<un>: recipe <r> status <s> progress <p> out <items> | unit_recipe <r>
--     capped <b> yielding <b> last spawn <s> ago | saving <item> rail <b>
local events = require("scripts.events")
-- the M1 fixture itself (place tools/probes/m1_acceptance.lua in the test copy's scripts/ next to this file)
pcall(require, "scripts.m1_acceptance")

local function status_name(s)
  for k, v in pairs(defines.entity_status) do
    if v == s then return k end
  end
  return tostring(s)
end

events.on_nth_tick(3600, function()
  local buildings = package.loaded["__" .. script.mod_name .. "__/scripts/buildings.lua"] or package.loaded["scripts.buildings"]
  if not (storage.ai and buildings) then return end
  local forces = {}
  for f in pairs(storage.ai) do forces[#forces + 1] = f end
  table.sort(forces)
  for _, f in ipairs(forces) do
    local C = storage.ai[f]
    for un, rec in buildings.for_force(f, "barracks") do
      local e = rec.entity
      if e and e.valid then
        local r = e.get_recipe()
        local out = e.get_output_inventory()
        local items = {}
        if out then
          for _, it in ipairs(out.get_contents()) do items[#items + 1] = it.name .. "=" .. it.count end
        end
        local N = C.nation or {}
        log(string.format("[rts] ai3 barracks diag t%d %s #%d: recipe %s status %s progress %.2f out [%s] | unit_recipe %s "
          .. "capped %s yielding %s last spawn %ds ago | saving %s rail %s | starved_since %s pull %s", game.tick, f, un,
          r and r.name or "nil", status_name(e.status), e.crafting_progress or 0, table.concat(items, " "),
          tostring(C.unit_recipe), tostring(C.capped), tostring(C.yielding ~= nil),
          (game.tick - (C.last_spawn_tick or 0)) / 60, tostring(N.saving), tostring(N.saving_rail),
          tostring(rec.starved_since), tostring(rec.pull_state)))
      end
    end
  end
end)

return {}
