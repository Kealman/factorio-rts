-- r2-econ (#8) test-only profiler: times market.ai_step and, inside it, the ledger parts (districts.ledger, stock,
-- flows, hint, make_targets) and the logistics and market calls inside it; each ai_step that made such a call is logged
-- as "[rts] r2e prof t<tick> slice <k> <force> ai_step: ..." and "[rts] r2e prof t<tick>   <module>.<fn> xN: ..."
-- (LuaProfiler, log only; nested calls are counted in their callers too). Use with the perf scene:
--   EXTRA_LUA=tools/probes/r2e_prof.lua SEED=701 tools/perf-bench.sh scene r2e-prof 5
local events = require("scripts.events")
local util = require("scripts.util")
local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. string.gsub(name, "%.", "/") .. ".lua"] or l["scripts." .. name]
end
local market, districts, logistics = mod("market"), mod("districts"), mod("logistics")
local inside, acc, order = false, {}, {}
local function wrap(tbl, tname, fname)
  local f = tbl and tbl[fname]
  if type(f) ~= "function" then return end
  tbl[fname] = function(...)
    if not inside then return f(...) end
    local key = tname .. "." .. fname
    local a = acc[key]
    if not a then
      a = {n = 0, p = helpers.create_profiler(true)}
      acc[key] = a
      order[#order + 1] = key
    end
    a.n = a.n + 1
    a.p.restart()
    local r = table.pack(f(...))
    a.p.stop()
    -- (restart resets: keep the sum in a second profiler)
    a.sum = a.sum or helpers.create_profiler(true)
    a.sum.add(a.p)
    return table.unpack(r, 1, r.n)
  end
end
for _, fn in ipairs({"ledger", "stock", "flows", "hint", "make_targets", "cities", "city_of"}) do wrap(districts, "districts", fn) end
for _, fn in ipairs({"set_policy", "policy", "hub_network", "haulers_of"}) do wrap(logistics, "logistics", fn) end
for _, fn in ipairs({"port_contents", "ports", "quote", "buy", "sell"}) do wrap(market, "market", fn) end
local step = market.ai_step
market.ai_step = function(C)
  local S = storage.market
  local A = S and S.ai and S.ai[C.force]
  local slice = A and A.slice or 0
  inside, acc, order = true, {}, {}
  local p = helpers.create_profiler()
  step(C)
  p.stop()
  inside = false
  -- log the slow ones only: a slice that ran a ledger read or any call (cheap filter: something was timed)
  if #order > 0 then
    log({"", string.format("[rts] r2e prof t%d slice %s %s ai_step: ", game.tick, tostring(slice), C.force), p})
    for _, key in ipairs(order) do
      local a = acc[key]
      log({"", string.format("[rts] r2e prof t%d   %s x%d: ", game.tick, key, a.n), a.sum})
    end
  end
end
