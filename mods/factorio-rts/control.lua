-- Control stage entry point.
--
-- Every module registers its event handlers through scripts/events.lua when it is first required, and
-- the bus calls handlers in that order. The order below is therefore load-bearing:
--   units first (registry), then the Phase 2 economy (buildings registry, production, economy summaries, base
--   template), match before camera (players are moved to the rts-player force and the lobby surface exists before
--   the camera is set up), fog after match, lobby after the HUD (its join handler shows the start dialog over the
--   freshly built HUD) and after ai.init (lobby.init stops commanders that ai.init started outside a match),
--   debug last.
-- Each module's init() is idempotent; it runs on on_init and again on on_configuration_changed.
local events = require("scripts.events")

local modules = {
  require("scripts.units"),
  require("scripts.buildings"),
  require("scripts.production"),
  require("scripts.economy"),
  require("scripts.basetemplate"),
  require("scripts.match"),
  require("scripts.sched"),    -- Phase 5 M3 perf: the work-unit scheduler (Nation jobs; after match: its teardown)
  require("scripts.ai.init"),  -- Phase 3 AI commanders; after match (ai.init reads storage.match.config)
  require("scripts.supply"),   -- Phase 4 supply cap (production's kit gate, HUD strip)
  require("scripts.research"), -- Phase 4 labs, technologies, kit gate; after ai.init (it re-sets the AI's
                               -- on_entity_damaged filter with the armored unit names added)
  require("scripts.fog"),      -- Phase 3 fog of war (charts around own units and buildings)
  require("scripts.camera"),   -- also requires scripts.cursor
  require("scripts.cursor"),
  require("scripts.selection"),
  require("scripts.orders"),
  require("scripts.divisions"), -- Phase 5: divisions (unit groups) and the order router; after orders (path-request
                                -- queue) and selection (division hooks). ai/army.lua requires it already, so its
                                -- handlers register inside ai.init's require chain, right after orders.lua's
  require("scripts.logistics"), -- Phase 4: hubs, stockpile policies, haulers (after orders: right-click hook)
  require("scripts.hubgui"),    -- Phase 4: hub and hauler panels
  require("scripts.rails"),     -- Phase 5 M1: depots, line planner, trains (after logistics: depots are hubs, and
                                -- after orders: its right-click hook follows the haulers')
  require("scripts.railroutes"), -- 0.1.2 (#31 part B): multi-stop train schedules (after rails: its hooks)
  require("scripts.railgui"),   -- Phase 5 M1: train and depot rail panels
  require("scripts.demolish"),  -- Phase 5: demolish own buildings (Delete, Demolish buttons)
  require("scripts.commander"), -- Phase 4: Commander hero (after logistics: its right-click hook follows the haulers')
  require("scripts.territory"), -- Phase 5 M1: ownership grid, borders, build rules, attrition (Nation mode; after
                                -- logistics and commander: hubs and forts are sources, the build check sits in buildings)
  require("scripts.cities"),    -- Phase 5 M1: City Centers, the capital, tiers, make targets (after territory)
  require("scripts.itempicker"), -- Phase 5 M1 QA round 1: make-target item picker (city panel and ledger)
  require("scripts.citygui"),   -- Phase 5 M1: city panel and city list (after cities, before the HUD)
  require("scripts.abilities"), -- Phase 4: abilities (after research: adds the Commander to the damage filter; its
                                -- targeted-ability right-click hook is registered first)
  require("scripts.abilitygui"), -- Phase 4: ability bar (bottom centre)
  require("scripts.hud"),
  require("scripts.divisiongui"), -- Phase 5: division panel; after the HUD (hud.on_refresh hook)
  require("scripts.lobby"),    -- Phase 3 start dialog, menu, results; match start / restart
  require("scripts.techgui"),  -- Phase 4 research panel (T)
  require("scripts.ages"),      -- Phase 5 E1: ages and the Railway Charter (after research, supply, match)
  require("scripts.districts"), -- Phase 5 E1: districts, oil, make targets, ledger data (after ages, production)
  -- Phase 5 M2 war: supply points and crates, city capture, garrisons and troop trains (Nation mode). After divisions,
  -- rails, territory, cities and ages (their hooks), after research (the Armor heal it takes back while low) and after
  -- cities (its capital-armor heal runs before the subdue clamp)
  require("scripts.warsupply"),
  require("scripts.capture"),
  require("scripts.garrison"),
  require("scripts.ledgergui"), -- Phase 5 E1: city ledger (L) and age badge (after hud: its styles)
  require("scripts.strategic"), -- Phase 5 M2 world: chart labels, regional minimap, strategic zoom (after cities, hud)
  require("scripts.population"), -- Phase 5 M2 people: residents, needs, growth, tiers by population, houses, food
                                 -- (after cities and districts: founding signals, the city ledger)
  require("scripts.labor"),      -- Phase 5 M2 people: staffing through labor modules, priorities, recruits (after
                                 -- population; production.lua's recruit gate and staffing hooks)
  -- Phase 5 M2 treasury: the treasury (after research: it wraps production.kit_gate for "unpaid"), the world market and
  -- trade ports (after logistics, world and the AI deps: ports are hub subtypes, ai/commander.lua calls deps.market),
  -- the market panel (M, after the HUD)
  require("scripts.treasury"),
  require("scripts.market"),
  require("scripts.marketgui"),
  -- Phase 5 M2 diplomacy: states, relations, proposals (diplomacy.lua is already loaded by orders.lua and the AI, whose
  -- targeting asks diplomacy.hostile; listed here for its init), wars and victory (after cities, territory and lobby),
  -- and the F4 panel (after the HUD: hud.lua's key table calls diplomacygui.toggle)
  require("scripts.diplomacy"),
  require("scripts.wars"),
  require("scripts.diplomacygui"),
  -- Phase 5 M3 air: plane supply, return, crash, airfields, patrols, the AA turret feed (after production, research,
  -- treasury: it wraps their kit gate; after divisions, orders, warsupply and fog: their hooks) and the airfield panel
  -- (Y, after the HUD: hud.lua's key table calls airgui.toggle)
  require("scripts.air"),
  require("scripts.airgui"),
  -- Phase 5 M3 age3: Age III and the Space Program, automation kits and the nuclear plant (after ages, districts,
  -- population, labor, treasury and the ledger: their hooks), rare extractors and bonuses (after age3: its ledger
  -- lines), money sinks and city-state trade (after market, garrison, diplomacy and the city and market panels)
  require("scripts.age3"),
  require("scripts.rare"),
  require("scripts.sinks"),
  -- Phase 5 M3 war2: fronts per war and hold_line (after territory, cities, divisions and wars), fort belts (after
  -- orders, logistics and cities), artillery and armoured trains (after rails, railgui and garrison: train kinds, the
  -- troop wagon set, disband hook); hud.lua's P4.KEYS reach them at run time
  require("scripts.fronts"),
  require("scripts.belts"),
  require("scripts.trainswar"),
  -- 0.1.1 (issue #16): guided objectives (after the HUD and the lobby: their layout and the lobby switch; after the
  -- modules whose events and signals tick the steps)
  require("scripts.netwait"),   -- 0.1.2 (#26): ghosts waiting for items in a hub / city network (read-only; panels and alert)
  require("scripts.objectives"),
  require("scripts.debug"),
}

-- Phase 5 M2 integration: the protected rails, signals and poles join the shared on_entity_damaged filter after every
-- module set its part of it (scripts/research.lua, scripts/abilities.lua)
require("scripts.targeting").install_damage_filters()

for _, module in ipairs(modules) do
  if module.init then
    events.on_init(module.init)
    events.on_configuration_changed(module.init)
  end
end
