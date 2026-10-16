-- Late-bound modules for the AI (Phase 4). scripts/supply.lua, scripts/research.lua and scripts/logistics.lua load
-- after scripts.ai.init in control.lua, and research.lua must set its on_entity_damaged filter after ai/init.lua
-- sets its own (the filter is one per mod; research's is the union). ai/init.lua therefore requires them at its very
-- end and stores them here; the AI modules read deps.<name> at run time, never at load time.
--
--   deps.supply     scripts/supply.lua    (get, cap, used, cost)
--   deps.research   scripts/research.lua  (queue, cancel, status, list, is_unlocked, lab_counts)
--   deps.logistics  scripts/logistics.lua (set_policy, haulers_of, set_home, stats, networks)
return {}
