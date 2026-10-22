-- Phase 5 M3 ai: scripted war probe for the council paths the acceptance seeds never reached (docs/PHASE5-M3.md D7;
-- scripts/ai/council.lua): holding divisions, interceptors, bombers, artillery trains at sieges, mercenaries and hired
-- garrisons. Test-only module for tools/autotest-run.sh (EXTRA_LUA) on a 1v1 Nation match of hard AIs:
--   KEEP_TREE=build/m3ai-tree9/factorio-rts EXTRA_LUA=tools/probes/ai3_war_paths.lua STOP_ON=RTS_WARPATHS_DONE \
--     DURATION_MIN=50 SEED=811 SPEED=10 tools/autotest-run.sh m3ai-war-811 '{opponents = 1, difficulty = "hard",
--     mode = "nation", world_size = 2048, enemy_brain = "ai"}' 3000
-- The subject is rts-player's AI nation (F: a running hard commander, aggressive doctrine, see DOCTRINES below);
-- rts-ai-1 (E) has its commander stopped, so its units only do what the probe orders. The probe builds real game state
-- and lets the AI's own code act on it; all paths run side by side (the AI's first offensive comes at minute 4-9):
--   setup  (8 s into the match) F: Fortification, Military railways, Aviation, Air Force researched (its age stays as
--          it is: the council paths do not read it), 6000 cr (topped up below 3000); two towns of E: town C 175-195
--          tiles from F's capital towards E (its land does not touch F's), town F 110-130 tiles to the side (its land
--          touches F's: a front); F declares war on E with the goal cities town C and E's capital (wars.declare); an
--          airfield in F's capital land on the side away from town F (script-built, one per city); an own rail depot
--          of F inside its land within artillery_range of town C, its network kept stocked with locomotive and
--          artillery wagon kits, coal and rail shells until the artillery path ran
--   mercs  waves of 6 walkers of E attack-move at F's capital centre (from the town F side): money_step hires garrison
--          points at the capital (sinks.hire_garrison); mercenaries need a port (the AI's envoy takes one; the probe
--          hands F the nearest free port when it has none 3 minutes in), a small idle army and free supply, so later
--          waves only start while F's army is out on an offensive, no defence group stands, F's pool is at most 22 (a
--          defence takes half of it), the council's merc_next has passed and F has 14 free supply (the probe
--          researches F's next Supply technology when it has less: the AI's barracks keep it at its cap)
--   air    a scout plane of E over F's capital (on the town F side, again every 2 minutes while unseen); once F's intel
--          saw it, 3 interceptors and 3 bombers of F at its airfield: air_step sends the interceptors to patrol the
--          capital
--   holds  2 scout planes of F (air_step makes them the air patrol over the most threatened front segment), 10 walkers
--          of E 82 tiles beyond the segment's middle (behind town F): F's scouts see them, the front's enemy strength
--          rises, holds_step forms a holding division from F's idle units (F walkers are spawned at its rally while it
--          has fewer than 12 idle)
--   strike F's army goes for its war goal town C on its own (a capture operation; 24 more walkers at its rally when no
--          capture started 3 minutes after its build order set the attack size, or by minute 22): in the advance or
--          siege phase air_step flies the bombers at it (a bomb operation), and the siege deploys an artillery train at
--          the depot (council siege_artillery)
--   end    once every path ran the probe watches 5 more minutes (the bomb run's strike and return, the train's fire,
--          the hold) and logs "[rts] ai3 war paths: follow-up ..."; the summary comes then, at the deadline (32
--          minutes after the setup), or when the match ends (F may take E's capital, its second war goal: a conquest
--          victory)
-- Log lines "[rts] ai autotest check ai3_path_<name>: PASS|FAIL <evidence>" (mercenaries, hire_garrison,
-- interceptors, holding_division, bombers, artillery_train), "[rts] ai3 war paths: ..." progress lines, the summary
-- "[rts] ai3 war paths summary <pass>/<total> ..." and the stop marker RTS_WARPATHS_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local cities = require("scripts.cities")
local territory = require("scripts.territory")
local wars = require("scripts.wars")
local fronts = require("scripts.fronts")
local rails = require("scripts.rails")
local trainswar = require("scripts.trainswar")
local logistics = require("scripts.logistics")
local market = require("scripts.market")
local treasury = require("scripts.treasury")
local research = require("scripts.research")
local ages = require("scripts.ages")
local air = require("scripts.air")
local supply = require("scripts.supply")
local ai_init = require("scripts.ai.init")
local autotest = require("scripts.ai.autotest")
local diplomacy = require("scripts.diplomacy")
local army = require("scripts.ai.army")
local council = require("scripts.ai.council")
local intel = require("scripts.ai.intel")

local F, E = "rts-player", "rts-ai-1"
-- F aggressive: an economic AI (ceasefire past 30 % weariness) sued for a ceasefire at 6:54 in seed 811, the probe's
-- attack waves had cost it 38 %, and the stopped E accepted, so its group at the subdued town C turned home before
-- the siege; the aggressive doctrine asks past 50 %. (E's doctrine only matters for its answers.)
autotest.DOCTRINES = {[F] = "aggressive", [E] = "economic"}
local MIN = 60 * 60
local SETUP_AT = 8 * 60
local DEADLINE = 32 * MIN          -- after the setup: every path not run by then fails
local OBSERVE = 5 * MIN            -- once every path ran: the bomb run's return, the train's fire, then the summary
local PORT_AFTER = 3 * MIN         -- the probe hands F a port when the AI has none by then
local PUSH_AFTER_MIN = 3 * MIN     -- no capture this long after the army step set C.army.min: more walkers
local PUSH_AT = 22 * MIN           -- ... or by then
local TECHS = {"rts-fortification", "rts-military-railways", "rts-aviation", "rts-air-force"}
local PATHS = {"mercenaries", "hire_garrison", "interceptors", "holding_division", "bombers", "artillery_train"}
local MONEY_LOW, MONEY_ADD = 3000, 4000
local SUPPLY_TECHS = {"rts-supply-1", "rts-supply-2", "rts-supply-3"}
local SUPPLY_ROOM = 14             -- free supply before a mercenaries wave (a template is 6-8 supply; the barracks
                                   -- fill 2-3 more before the council's pass: 10 was refused in seed 806)
local PLANE_KIND = {["scout-plane"] = true, bomber = true, interceptor = true}

local function W()
  local s = storage.warpaths
  if not s then
    s = {step = "wait", pass = 0, fail = 0, res = {}, ops = {}, waves = 0, extra = 0, foe_planes = 0}
    storage.warpaths = s
  end
  return s
end

local function check(name, ok, fmt, ...)
  local s = W()
  if s.res[name] then return end
  s.res[name] = ok and "PASS" or "FAIL"
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("ai autotest check ai3_path_%s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

local function note(fmt, ...) util.log("ai3 war paths: " .. fmt, ...) end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function unit_vec(dx, dy)
  local l = math.sqrt(dx * dx + dy * dy)
  if l < 1e-6 then return 1, 0 end
  return dx / l, dy / l
end

local function rotate(x, y, deg)
  local a = math.rad(deg)
  return x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)
end

local function surface() return game.surfaces[storage.match.surface] end
local function K() return council.state(F) end
local function C() return storage.ai and storage.ai[F] end
local function stats() local k = K() return k and k.stats or {} end

local function capital(force)
  local N = storage.nations and storage.nations[force]
  return N and N.capital and cities.get(N.capital) or nil
end

-- Water to grass, trees, rocks, cliffs and fish gone in a square of radius r around (x, y).
local function clear(sf, x, y, r)
  local area = {{x - r, y - r}, {x + r, y + r}}
  local tiles = {}
  for _, t in ipairs(sf.find_tiles_filtered({area = area, collision_mask = "water_tile"})) do
    tiles[#tiles + 1] = {name = "grass-1", position = t.position}
  end
  if #tiles > 0 then sf.set_tiles(tiles, true) end
  for _, e in ipairs(sf.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "fish"}})) do
    if e.valid then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
end

local function spawn_n(name, n, force, at, cols)
  local list = {}
  cols = cols or 5
  for k = 1, n do
    local e = units.spawn(name, {x = at.x + ((k - 1) % cols) * 2.5, y = at.y + math.floor((k - 1) / cols) * 2.5},
      force, nil, surface())
    if e then list[#list + 1] = e end
  end
  return list
end

local function money()
  if treasury.balance(F) < MONEY_LOW then treasury.add(F, MONEY_ADD, "probe") end
end

-- F's idle units the council may draw from (council.lua free_units' rule).
local function free_idle()
  local Cf = C()
  local a = Cf and Cf.army
  if not a then return 0 end
  local held = a.held or {}
  local n = 0
  for un, rec in units.for_force(F) do
    if not a.member[un] and not held[un] and not army.POOL_SKIP[rec.kind] and not PLANE_KIND[rec.kind]
       and rec.issuer ~= "market" and rec.order == units.IDLE and not divisions.of_unit(un) and rec.entity.valid then
      n = n + 1
    end
  end
  return n
end

-- An army defence group (not a town relief) stands: a new attack on the capital does not split the pool again.
local function defending()
  local Cf = C()
  for _, G in pairs(Cf and Cf.army and Cf.army.groups or {}) do
    if G.state == "defend" and not G.relief then return true end
  end
  return false
end

local function attack_out()
  local Cf = C()
  for _, G in pairs(Cf and Cf.army and Cf.army.groups or {}) do
    if G.state == "attack" then return true end
  end
  return false
end

local function council_line()
  local Cf = C()
  return string.format("%s | %s | army %s | free idle %d | balance %.0f | supply %.0f/%.0f | ports [%s]",
    council.describe(F), intel.describe(F), Cf and Cf.army and army.describe(Cf) or "-", free_idle(),
    treasury.balance(F), supply.used(F), supply.cap(F), table.concat(market.ports(F), " "))
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local function town_spot(sf, home, dirs, dists, min_home)
  for _, d in ipairs(dists) do
    for _, v in ipairs(dirs) do
      local p = {x = math.floor(home.x + v[1] * d) + 0.0, y = math.floor(home.y + v[2] * d) + 0.0}
      if sf.is_chunk_generated({math.floor(p.x / 32), math.floor(p.y / 32)}) and util.distance(p, home) >= min_home
         and territory.can_build(E, cities.CENTER, p)
         and sf.can_place_entity({name = cities.CENTER, position = p, force = E,
                                  build_check_type = defines.build_check_type.manual_ghost, forced = true}) then
        return p, d
      end
    end
  end
  return nil
end

local function found_town(sf, spot, tag)
  clear(sf, spot.x, spot.y, 12)
  local id = cities.found(E, spot, {why = "(war paths probe: town " .. tag .. ")"})
  territory.flush()
  return id
end

local function stock_depot(s)
  local net = s.depot and logistics.hub_network(s.depot)
  if not net then return -1 end
  local want = {[rails.LOCO_KIT] = 4, [rails.ARTY_KIT] = 2, [rails.FUEL] = 100, [trainswar.SHELL] = 60}
  local added = 0
  for _, item in ipairs(sorted_keys(want)) do
    local have = net.get_item_count(item)
    if have < want[item] then added = added + net.insert({name = item, count = want[item] - have}) end
  end
  return added
end

local function place_depot(s, sf, home, target)
  local ux, uy = unit_vec(target.x - home.x, target.y - home.y)
  local tried = 0
  for _, along in ipairs({82, 78, 86, 74, 70, 66}) do
    for _, side in ipairs({0, 14, -14, 28, -28}) do
      local p = {x = math.floor(home.x + ux * along - uy * side) + 0.0,
                 y = math.floor(home.y + uy * along + ux * side) + 0.0}
      if tried < 6 and util.distance(p, target) <= 104 and util.distance(p, home) <= 90
         and territory.owner_at(p) == F then
        local busy = 0
        for _, e in ipairs(sf.find_entities_filtered({area = {{p.x - 24, p.y - 24}, {p.x + 24, p.y + 24}},
                                                      force = {F, E}})) do
          if e.type ~= "unit" and e.type ~= "spider-unit" then busy = busy + 1 end
        end
        if busy == 0 then
          tried = tried + 1
          clear(sf, p.x, p.y, 26)
          local dep = sf.create_entity({name = "rts-depot", position = p, force = F, raise_built = true})
          local d = dep and rails.depot(dep.unit_number)
          if d and d.platform and logistics.hub_network(dep.unit_number) then
            s.depot = dep.unit_number
            s.depot_pos = {x = dep.position.x, y = dep.position.y}
            return true
          end
          note("depot at %s refused (entity %s, platform %s): next spot", util.pos_str(p), tostring(dep ~= nil),
            tostring(d ~= nil and d.platform ~= nil))
          if dep and dep.valid then dep.destroy({raise_destroy = true}) end
        end
      end
    end
  end
  return false
end

-- The airfield on the side of the capital facing away from (ax, ay).
local function place_airfield(s, sf, cap, ax, ay)
  for _, r in ipairs({34, 42, 28, 50}) do
    for _, deg in ipairs({180, 150, 210, 120, 240}) do
      local vx, vy = rotate(ax, ay, deg)
      local want = {x = cap.position.x + vx * r, y = cap.position.y + vy * r}
      local pos = sf.find_non_colliding_position(air.AIRFIELD, want, 10, 1, true)
      if pos and air.can_build_airfield(F, pos) then
        clear(sf, pos.x, pos.y, 8)
        local e = sf.create_entity({name = air.AIRFIELD, position = pos, force = F, raise_built = true})
        if e and air.airfield_of_city(F, cap.id) then
          s.field = e.unit_number
          s.field_pos = {x = e.position.x, y = e.position.y}
          return true
        end
        if e and e.valid then e.destroy({raise_destroy = true}) end
      end
    end
  end
  return false
end

local function setup(s)
  local sf = surface()
  local Cf = C()
  local cap, ecap = capital(F), capital(E)
  if not (Cf and cap and ecap and sf) then
    note("setup: no AI commander, capital or rival capital for %s (%s %s %s)", F, tostring(Cf ~= nil),
      tostring(cap ~= nil), tostring(ecap ~= nil))
    return false
  end
  ai_init.stop_force(E)
  local home = cap.position
  local ux, uy = unit_vec(ecap.position.x - home.x, ecap.position.y - home.y)
  s.home, s.u = {x = home.x, y = home.y}, {x = ux, y = uy}
  -- technologies, Age III, money
  local force = game.forces[F]
  for _, t in ipairs(TECHS) do
    local tech = force.technologies[t]
    if tech and not tech.researched then tech.researched = true end
  end
  -- (the age stays: none of these paths reads it, and a jump to Age III at minute 0 sent the economic AI after Age III
  -- district targets with its iron at 0, so its build order never reached the army step: no offensive in 16 minutes)
  research.apply(force)
  treasury.add(F, 6000, "probe")
  -- the two towns of E (chunks out to 200 tiles generated first)
  for _, deg in ipairs({0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180}) do
    local vx, vy = rotate(ux, uy, deg)
    sf.request_to_generate_chunks({home.x + vx * 190, home.y + vy * 190}, 2)
    sf.request_to_generate_chunks({home.x + vx * 120, home.y + vy * 120}, 2)
  end
  sf.force_generate_chunk_requests()
  local dirs_c = {}
  for _, deg in ipairs({0, 15, -15, 30, -30, 45, -45}) do
    local vx, vy = rotate(ux, uy, deg)
    dirs_c[#dirs_c + 1] = {vx, vy}
  end
  local spot_c = town_spot(sf, home, dirs_c, {180, 186, 175, 192}, 172)
  s.town_c = spot_c and found_town(sf, spot_c, "C")
  local dirs_f = {}
  for _, deg in ipairs({90, -90, 120, -120, 150, -150, 180}) do
    local vx, vy = rotate(ux, uy, deg)
    dirs_f[#dirs_f + 1] = {vx, vy}
  end
  local spot_f = town_spot(sf, home, dirs_f, {118, 114, 122, 110, 126}, 100)
  s.town_f = spot_f and found_town(sf, spot_f, "F")
  local tc, tf = s.town_c and cities.get(s.town_c), s.town_f and cities.get(s.town_f)
  s.town_c_pos = tc and {x = tc.position.x, y = tc.position.y}
  s.town_f_pos = tf and {x = tf.position.x, y = tf.position.y}
  -- (the attack waves come from the town F side, the airfield stands on the other side of the capital)
  local fx, fy = ux, uy
  if s.town_f_pos then fx, fy = unit_vec(s.town_f_pos.x - home.x, s.town_f_pos.y - home.y) end
  s.wf = {x = fx, y = fy}
  -- the war: F on E, goals town C and E's capital
  local goals = {}
  if s.town_c then goals[#goals + 1] = s.town_c end
  goals[#goals + 1] = ecap.id
  local war, why = wars.declare(F, E, {kind = "conquest", cities = goals})
  s.war = war
  fronts.refresh()
  -- the airfield and the depot
  local field_ok = place_airfield(s, sf, cap, fx, fy)
  local depot_ok = tc and place_depot(s, sf, home, tc.position)
  local stocked = depot_ok and stock_depot(s) or -1
  money()
  note("setup at %s: %s capital %d at %s, %s capital %d at %s (%.0f tiles); techs [%s] age %d; balance %.0f; ports "
    .. "[%s]; town C %s at %s (%.0f tiles from %s's capital), town F %s at %s (%.0f tiles); war %s (%s) goals [%s]; "
    .. "airfield %s at %s; depot %s at %s (%.0f tiles from town C, %d items stocked); %s commander stopped",
    util.pos_str(home), F, cap.id, util.pos_str(home), E, ecap.id, util.pos_str(ecap.position),
    util.distance(home, ecap.position), table.concat(TECHS, " "), ages.of(F), treasury.balance(F),
    table.concat(market.ports(F), " "), tostring(s.town_c), s.town_c_pos and util.pos_str(s.town_c_pos) or "-",
    s.town_c_pos and util.distance(s.town_c_pos, home) or 0, F, tostring(s.town_f),
    s.town_f_pos and util.pos_str(s.town_f_pos) or "-", s.town_f_pos and util.distance(s.town_f_pos, home) or 0,
    tostring(war), tostring(why), table.concat(goals, " "), tostring(s.field), s.field_pos and util.pos_str(s.field_pos)
    or "-", tostring(s.depot), s.depot_pos and util.pos_str(s.depot_pos) or "-",
    (s.depot_pos and s.town_c_pos) and util.distance(s.depot_pos, s.town_c_pos) or 0, stocked, E)
  s.setup_ok = (war ~= nil and s.town_c ~= nil and s.town_f ~= nil and field_ok and depot_ok) and true or false
  return true
end

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------
-- Mercenaries and hired garrisons: attack waves on the capital.
local function wave_alive(s)
  local n = 0
  for _, un in ipairs(s.wave or {}) do if units.get(un) then n = n + 1 end end
  return n
end

local function attack_wave(s, why)
  local home = s.home
  local at = {x = home.x + s.wf.x * 24, y = home.y + s.wf.y * 24}
  local list = spawn_n("rts-walker", 6, E, at, 3)
  orders.attack_move(list, {x = home.x, y = home.y})
  s.wave = {}
  for _, e in ipairs(list) do s.wave[#s.wave + 1] = e.unit_number end
  s.waves = s.waves + 1
  s.wave_t = game.tick
  local Cf = C()
  note("mercs: wave %d (%s): %d walkers of %s attack-move at %s's capital from %s (free idle %d, pool size %s, attack "
    .. "out %s, ports [%s], supply %.0f/%.0f)", s.waves, why, #list, E, F, util.pos_str(at), free_idle(),
    tostring(Cf and Cf.army and Cf.army.pool_size), tostring(attack_out()), table.concat(market.ports(F), " "),
    supply.used(F), supply.cap(F))
end

local function mercs_step(s, tick)
  local st = stats()
  local Cf = C()
  local a = Cf and Cf.army
  if a and a.threat and tick - a.threat.tick <= 300 then
    s.min_pool = math.min(s.min_pool or 1e9, a.pool_size or 0)
  end
  if (st.hires or 0) >= 1 and not s.hire_t then s.hire_t, s.hire_pool = tick, a and a.pool_size end
  if (st.mercs or 0) >= 1 and not s.merc_t then s.merc_t, s.merc_pool = tick, a and a.pool_size end
  -- a port: the AI's envoy takes one; the probe hands over the nearest free one when it has none after PORT_AFTER
  if #market.ports(F) == 0 and tick - s.t0 >= PORT_AFTER and not s.port_given and storage.market
     and storage.market.ports then
    local best, bd
    for _, un in ipairs(sorted_keys(storage.market.ports)) do
      local p = storage.market.ports[un]
      if p.entity.valid and not p.owner then
        local d = util.distance(p.position, s.home)
        if not bd or d < bd then best, bd = un, d end
      end
    end
    if best then
      s.port_given = best
      market.set_owner(best, F)
      note("mercs: %s has no port %d s in: the probe hands it port #%d (%.0f tiles)", F, (tick - s.t0) / 60, best, bd)
    end
  end
  local hire_done, merc_done = s.res.hire_garrison ~= nil, s.res.mercenaries ~= nil
  if (st.hires or 0) >= 1 and not hire_done then
    local cap = capital(F)
    local gar = storage.garrison and cap and storage.garrison.cities and storage.garrison.cities[cap.id]
    check("hire_garrison", gar ~= nil and (gar.hired or 0) > 0,
      "council stats hires %d at %.0f s (wave %d); capital city %s hired points %.1f; idle pool %s then", st.hires,
      (s.hire_t - s.t0) / 60, s.waves, cap and tostring(cap.id) or "-", gar and gar.hired or 0, tostring(s.hire_pool))
  end
  if (st.mercs or 0) >= 1 and not merc_done then
    local merc_div
    for _, D in ipairs(divisions.for_force(F)) do
      if type(D.name) == "table" and D.name[1] == "rts-age3.mercenary-name" then merc_div = D end
    end
    check("mercenaries", merc_div ~= nil,
      "council stats mercs %d at %.0f s (wave %d); division #%s %s (%d units, state %s, owner %s); ports [%s]; "
      .. "idle pool %s when hired; balance %.0f, supply %.0f/%.0f now", st.mercs, (s.merc_t - s.t0) / 60, s.waves,
      merc_div and tostring(merc_div.id) or "-", merc_div and serpent.line(merc_div.name, {comment = false}) or "-",
      merc_div and #divisions.members(merc_div.id) or 0, merc_div and tostring(merc_div.state) or "-",
      merc_div and tostring(merc_div.owner) or "-", table.concat(market.ports(F), " "), tostring(s.merc_pool),
      treasury.balance(F), supply.used(F), supply.cap(F))
  end
  if s.res.hire_garrison and s.res.mercenaries then return end
  -- the next wave
  if s.waves >= 14 or (s.wave and wave_alive(s) > 0 and tick - s.wave_t < 45 * 60)
     or (s.wave_t and tick - s.wave_t < 20 * 60) then
    return
  end
  local pool = a and a.pool_size or 0
  if not s.res.hire_garrison and s.waves < 2 then
    attack_wave(s, "garrison")
  elseif not s.res.mercenaries and #market.ports(F) > 0 and attack_out() and pool <= 22 and not defending()
         and tick >= ((K() or {}).merc_next or 0) then
    -- (merc_next: the council tries again 2 minutes after any attempt; waves before it only add war weariness.
    -- attack_out: mercenaries hired before the first offensive (at a port 1000 tiles away) joined its group, whose
    -- centroid then lagged 270 tiles behind its fast units: they took town C before the siege phase, no artillery
    -- train in seed 811; an AI issue reported with this probe)
    -- (a new defence takes half the idle pool, so pool_size falls below merc_army; the template needs free supply:
    -- the AI's barracks keep it at its cap, "cannot hire mercenaries: supply" in seed 811, so the probe researches
    -- F's next Supply technology when it has less than SUPPLY_ROOM free)
    for _, t in ipairs(SUPPLY_TECHS) do
      local tech = game.forces[F].technologies[t]
      if supply.cap(F) - supply.used(F) < SUPPLY_ROOM and tech and not tech.researched then
        tech.researched = true
        research.apply(game.forces[F])
        s.supply_techs = (s.supply_techs or 0) + 1
        note("mercs: %s at supply %.0f/%.0f: the probe researches %s", F, supply.used(F), supply.cap(F), t)
      end
    end
    if supply.cap(F) - supply.used(F) >= SUPPLY_ROOM then
      attack_wave(s, attack_out() and "army out" or "small pool")
    end
  end
end

-- Interceptors: an enemy plane over the capital.
local function air_spawn(s)
  local fp = s.field_pos or s.home
  local inter = spawn_n("rts-interceptor", 3, F, {x = fp.x + 6, y = fp.y + 6}, 3)
  local bomb = spawn_n("rts-bomber", 3, F, {x = fp.x - 6, y = fp.y + 6}, 3)
  note("air: %d interceptors and %d bombers of %s at its airfield %s", #inter, #bomb, F, util.pos_str(fp))
end

-- (on the town F side of the capital, 12 tiles from its centre: in sight of its buildings, away from the airfield's
-- planes, which shot it down before intel's scan saw it in seed 805)
local function foe_plane(s)
  local h = s.home
  local foe = units.spawn("rts-scout-plane", {x = h.x + s.wf.x * 12, y = h.y + s.wf.y * 12}, E, nil, surface())
  s.foe_planes = s.foe_planes + 1
  s.foe_t = game.tick
  note("air: scout plane %d of %s over %s's capital at %s", s.foe_planes, E, F,
    foe and util.pos_str(foe.position) or "-")
end

local function air_step(s, tick)
  local st = stats()
  if (st.interceptors or 0) >= 1 then
    local k = K()
    local div = k and k.air and k.air.interceptors
    local D = div and divisions.get(div)
    local seen = intel.enemy_planes_seen(F)
    check("interceptors", D ~= nil,
      "council stats interceptors %d at %.0f s; division #%s (%s, %d planes, state %s); enemy planes seen %s s ago; "
      .. "Air Force %s, airfield %s", st.interceptors, (tick - s.t0) / 60, tostring(div), D and tostring(D.name) or "-",
      D and #divisions.members(div) or 0, D and tostring(D.state) or "-",
      seen and string.format("%.0f", (tick - seen) / 60) or "never", tostring(research.has(F, "rts-air-force")),
      tostring(air.airfield_of_city(F, capital(F) and capital(F).id) ~= nil))
    return
  end
  local seen = intel.enemy_planes_seen(F)
  -- F's planes come once intel saw the enemy plane (or after 90 s)
  if not s.air_spawned and (seen or tick - s.t0 >= 90 * 60) then
    s.air_spawned = tick
    note("air: enemy planes seen by %s's intel: %s", F,
      seen and string.format("%.0f s ago", (tick - seen) / 60) or "not yet")
    air_spawn(s)
  end
  if (not seen or tick - seen > 2 * MIN) and tick - (s.foe_t or 0) >= 2 * MIN and s.foe_planes < 4 then foe_plane(s) end
end

-- Holding divisions: enemy strength near the front.
local function holds_spawn(s)
  if #fronts.segments(F) == 0 then fronts.flush() end
  local fp = s.field_pos or s.home
  local scouts = spawn_n("rts-scout-plane", 2, F, {x = fp.x, y = fp.y - 6}, 2)
  -- E's walkers 82 tiles beyond the middle of F's segment nearest town F, away from F: within near_radius (160) of
  -- it and in sight (plane_sight 64) of the scouts' patrol circle (48 around the middle) on its near side, out of a
  -- walker's 20-tile range of it (walkers 55 tiles from the middle shot both scouts down in seed 805)
  local foes = {}
  local at = s.home
  local seg = s.town_f_pos and fronts.nearest(F, s.town_f_pos)
  if seg and seg.mid then
    at = {x = seg.mid.x + s.wf.x * 82, y = seg.mid.y + s.wf.y * 82}
  elseif s.town_f_pos then
    at = {x = s.town_f_pos.x + s.wf.x * 40, y = s.town_f_pos.y + s.wf.y * 40}
  end
  if s.town_f_pos then foes = spawn_n("rts-walker", 10, E, at, 5) end
  local idle = free_idle()
  local mine = 0
  if idle < 12 and C() and C().army then mine = #spawn_n("rts-walker", 14 - idle, F, C().army.rally, 5) end
  local parts = {}
  for _, seg in ipairs(fronts.segments(F)) do
    parts[#parts + 1] = string.format("#%d chord %.0f strength %s threat %.0f", seg.id, seg.chord or 0,
      tostring(seg.strength), fronts.threat(seg))
  end
  note("holds: %d scout planes of %s at its airfield; %d walkers of %s behind town F at %s; %d idle units of %s (+%d "
    .. "at the rally); segments of %s: [%s]", #scouts, F, #foes, E, util.pos_str(at), idle, F, mine, F,
    table.concat(parts, "; "))
end

local function holds_step(s, tick)
  local st = stats()
  local k = K()
  if (st.holds or 0) >= 1 then
    local ev = {}
    for _, id in ipairs(sorted_keys(k and k.holds or {})) do
      local H = k.holds[id]
      local D = divisions.get(H.div)
      local seg = fronts.segment(F, id)
      local line = storage.fronts and storage.fronts.lines and storage.fronts.lines[H.div]
      ev[#ev + 1] = string.format("segment %d (strength %s, threat %.0f, holder %s): division #%d %s, %d units, state "
        .. "%s, stance %s, line phase %s", id, seg and tostring(seg.strength) or "-", fronts.threat(seg),
        seg and tostring(seg.holder) or "-", H.div, D and serpent.line(D.name, {comment = false}) or "-",
        D and #divisions.members(H.div) or 0, D and tostring(D.state) or "-", D and tostring(D.stance) or "-",
        line and tostring(line.phase) or "-")
    end
    local held = 0
    for _ in pairs(C() and C().army and C().army.held or {}) do held = held + 1 end
    check("holding_division", #ev > 0 and held > 0, "council stats holds %d at %.0f s; %d units in C.army.held; %s",
      st.holds, (tick - s.t0) / 60, held, #ev > 0 and table.concat(ev, " | ") or "no hold standing")
    return
  end
  if (tick - s.t0) % MIN == 0 then
    local parts = {}
    for _, seg in ipairs(fronts.segments(F)) do
      parts[#parts + 1] = string.format("#%d strength %s (intel near mid %.0f) threat %.0f", seg.id,
        tostring(seg.strength), seg.mid and intel.strength_near(F, E, seg.mid, 160) or -1, fronts.threat(seg))
    end
    local Kair = k and k.air or {}
    local P = Kair.patrol and divisions.get(Kair.patrol)
    note("holds: waiting: segments [%s]; air patrol #%s %s", table.concat(parts, "; "), tostring(Kair.patrol),
      P and tostring(P.state) or "-")
    if free_idle() < 10 and s.extra < 3 and C() and C().army then
      s.extra = s.extra + 1
      local n = #spawn_n("rts-walker", 12, F, C().army.rally, 4)
      note("holds: %d more walkers of %s at its rally (top-up %d)", n, F, s.extra)
    end
  end
end

-- Bombers and the artillery train: the capture of town C.
local function track_ops(s)
  local k = K()
  if not k then return end
  for _, id in ipairs(sorted_keys(k.ops)) do
    local op = k.ops[id]
    local r = s.ops[id]
    if not r then
      r = {kind = op.kind, phases = op.phase, city = op.target and op.target.city}
      s.ops[id] = r
    end
    r.kind = op.kind
    if not string.find(" " .. r.phases .. " ", " " .. op.phase .. " ", 1, true) then
      r.phases = r.phases .. " " .. op.phase
    end
    if type(op.artillery) == "number" then r.train = op.artillery end
    if op.artillery == "tried" then r.tried = true end
    if op.kind == "bomb" then r.division = op.divisions and op.divisions[1] end
  end
end

local function ops_text(s, pred)
  local parts = {}
  for _, id in ipairs(sorted_keys(s.ops)) do
    local r = s.ops[id]
    if (not pred or pred(r)) and r.kind ~= "defend" then
      parts[#parts + 1] = string.format("#%d %s [%s]%s%s%s", id, r.kind, r.phases,
        r.city and (" city " .. r.city) or "",
        r.train and (" train " .. r.train) or (r.tried and " artillery tried" or ""),
        r.division and (" division #" .. r.division) or "")
    end
  end
  return table.concat(parts, ", ")
end

local function strike_step(s, tick)
  local st = stats()
  local k = K()
  if (tick - s.t0) % 600 == 0 and (st.artillery or 0) < 1 then stock_depot(s) end
  local Cf = C()
  if Cf and Cf.army and Cf.army.min and not s.min_t then
    s.min_t = tick
    note("strike: %s's build order set the attack size %d at %.0f s", F, Cf.army.min, (tick - s.t0) / 60)
  end
  local capture_seen = false
  for _, r in pairs(s.ops) do
    if r.kind == "capture" or r.kind == "siege" then capture_seen = true end
  end
  if not capture_seen and not s.pushed and Cf and Cf.army
     and ((s.min_t and tick - s.min_t >= PUSH_AFTER_MIN) or tick - s.t0 >= PUSH_AT) then
    s.pushed = true
    local n = #spawn_n("rts-walker", 24, F, Cf.army.rally, 6)
    note("strike: no capture operation yet: %d more walkers of %s at its rally; %s", n, F, council_line())
  end
  if (st.bombs or 0) >= 1 and not s.res.bombers then
    local bombs = ops_text(s, function(r) return r.kind == "bomb" end)
    local Kair = k and k.air or {}
    local B = Kair.bombers and divisions.get(Kair.bombers)
    check("bombers", bombs ~= "",
      "council stats bombs %d at %.0f s; bomb ops [%s]; bomber division #%s (%d planes, state %s); capture ops [%s]",
      st.bombs, (tick - s.t0) / 60, bombs, tostring(Kair.bombers), B and #divisions.members(Kair.bombers) or 0,
      B and tostring(B.state) or "-", ops_text(s, function(r) return r.kind == "capture" or r.kind == "siege" end))
  end
  if (st.artillery or 0) >= 1 and not s.res.artillery_train then
    local train_id
    for _, id in ipairs(sorted_keys(s.ops)) do if s.ops[id].train then train_id = s.ops[id].train end end
    local train = train_id and game.train_manager.get_train_by_id(train_id)
    local wagons, shells, n = 0, 0, 0
    if train and train.valid then
      n = #train.carriages
      for _, c in ipairs(train.carriages) do if c.type == "artillery-wagon" then wagons = wagons + 1 end end
      shells = trainswar.shells(train)
    end
    check("artillery_train", train_id ~= nil and wagons >= 1,
      "council stats artillery %d at %.0f s; ops [%s]; train %s (%d carriages, %d artillery wagon(s), %d shells) from "
      .. "depot #%s %.0f tiles from town C %s", st.artillery, (tick - s.t0) / 60,
      ops_text(s, function(r) return r.train ~= nil or r.tried end), tostring(train_id), n, wagons, shells,
      tostring(s.depot), (s.depot_pos and s.town_c_pos) and util.distance(s.depot_pos, s.town_c_pos) or 0,
      tostring(s.town_c))
  end
end

-- After every path ran: what became of them (the bomb run's strike and return, the train's fire, the hold).
local function follow_up(s, tick)
  local k = K()
  local tw = storage.trainswar and storage.trainswar.stats and storage.trainswar.stats[F] or {}
  local Kair = k and k.air or {}
  local function div_text(id)
    local D = id and divisions.get(id)
    return string.format("#%s %s", tostring(id), D and (tostring(D.state) .. " " .. #divisions.members(id) .. " units")
      or "gone")
  end
  local by_city = {}
  for _, id in ipairs(sorted_keys(s.ops)) do
    local r = s.ops[id]
    if r.city and (r.kind == "capture" or r.kind == "siege") then
      by_city[r.city] = (by_city[r.city] or 0) + 1
    end
  end
  local dup = {}
  for _, c in ipairs(sorted_keys(by_city)) do
    if by_city[c] > 1 then dup[#dup + 1] = string.format("city %d: %d capture/siege ops", c, by_city[c]) end
  end
  note("follow-up %.0f s after the last path: ops [%s]; artillery train shots %d, deployed %d, rearmed %d; bombers %s, "
    .. "interceptors %s, air patrol %s; holds now %d (%d in all); several operations on one city: [%s]",
    (tick - s.observe_t) / 60, ops_text(s), tw.shots or 0, tw.deployed or 0, tw.rearmed or 0, div_text(Kair.bombers),
    div_text(Kair.interceptors), div_text(Kair.patrol), table_size(k and k.holds or {}), stats().holds or 0,
    table.concat(dup, "; "))
end

local function finish(s, tick)
  for _, p in ipairs(PATHS) do
    if not s.res[p] then check(p, false, "not reached within %.0f s: %s", (tick - s.t0) / 60, council_line()) end
  end
  if not s.res.bombers or not s.res.artillery_train then note("strike: ops [%s]", ops_text(s)) end
  local parts = {}
  for _, p in ipairs(PATHS) do parts[#parts + 1] = p .. " " .. s.res[p] end
  util.log("ai3 war paths summary %d/%d: %s | setup %s | %s", s.pass, #PATHS, table.concat(parts, ", "),
    s.setup_ok and "ok" or "INCOMPLETE", council.describe(F))
  s.step = "done"
  log("RTS_WARPATHS_DONE")
end

events.on_nth_tick(60, function(ev)
  local m = storage.match
  local ws = storage.warpaths
  if ws and ws.step == "run" and not (m and m.phase == "running") then
    -- the match ended under way (F took E's capital, a goal of its war: conquest victory at 26:08 in seed 806)
    note("the match ended (phase %s) %.0f s after the setup", tostring(m and m.phase), (ev.tick - ws.t0) / 60)
    if ws.observe_t then follow_up(ws, ev.tick) end
    finish(ws, ev.tick)
    return
  end
  if not (m and m.phase == "running" and m.tick_started and m.config and m.config.mode == "nation") then return end
  local s = W()
  if s.step == "done" then return end
  local tick = ev.tick
  if s.step == "wait" then
    if tick - m.tick_started < SETUP_AT then return end
    if not setup(s) then
      s.t0 = tick
      finish(s, tick)
      return
    end
    s.step, s.t0 = "run", tick
    return
  end
  local age = tick - s.t0
  money()
  track_ops(s)
  local st = diplomacy.state(F, E)
  if st ~= s.war_state then
    if s.war_state then note("%s / %s: %s -> %s at %.0f s", F, E, s.war_state, tostring(st), age / 60) end
    s.war_state = st
  end
  if age == 2 * 60 then
    foe_plane(s)
  elseif age == 4 * 60 then
    holds_spawn(s)
  end
  mercs_step(s, tick)
  if age > 2 * 60 then air_step(s, tick) end
  if age > 4 * 60 then holds_step(s, tick) end
  strike_step(s, tick)
  if age > 0 and age % (2 * MIN) == 0 then note("t+%d s: %s | ops [%s]", age / 60, council_line(), ops_text(s)) end
  local all = true
  for _, p in ipairs(PATHS) do if not s.res[p] then all = false end end
  if all and not s.observe_t then
    s.observe_t = tick
    note("every path ran at %.0f s: watching them for %.0f s more", age / 60, OBSERVE / 60)
  end
  if (s.observe_t and tick - s.observe_t >= OBSERVE) or age >= DEADLINE then
    if s.observe_t then follow_up(s, tick) end
    finish(s, tick)
  end
end)

return {}
