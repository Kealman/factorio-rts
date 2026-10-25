-- r2-ai probe, issue #5 (AI armies shrink in debt). Test-only module for tools/autotest-run.sh (EXTRA_LUA) on a
-- 4-nation Nation match of normal AIs:
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/ai3_debt.lua DURATION_MIN=34 SEED=801 SPEED=10 tools/autotest-run.sh ai3-debt-801 \
--     '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 4000
-- At minute DEBT_AT the AI nation with the largest army (by supply, as the treasury's upkeep counts it) is put into
-- debt: its balance is set to BALANCE and held below 0 for HOLD_MIN minutes (reset every 10 s while it rises above
-- BALANCE / 2), then released. Logged every 30 s: stage, balance, army supply and units, idle units. Checks:
--   debt_stage2   the nation reaches debt stage 2
--   debt_retire   3 minutes after stage 2 its army supply is at most KEEP (balance.nation.ai3.council.debt.keep_supply)
--                 plus one unit's worth, or no idle unit is left
--   debt_cap      until HOLD_MIN minutes after the start, its army never grows above the count right after retiring
local events = require("scripts.events")
local util = require("scripts.util")
local autotest = require("scripts.ai.autotest")
local balance = require("balance")
autotest.AI3_CHECKS = true

local DEBT_AT, HOLD_MIN, BALANCE = 22, 6, -300
local KEEP = (balance.nation.ai3.council.debt or {}).keep_supply or 40

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function army(force)
  local units, supply, divisions = mod("units"), mod("supply"), mod("divisions")
  local C = storage.ai and storage.ai[force]
  local a = C and C.army or {member = {}}
  local total, n, idle = 0, 0, 0
  for un, rec in units.for_force(force) do
    if rec.kind ~= "hauler" and rec.kind ~= "commander" and rec.entity.valid then
      total = total + supply.cost(rec.entity.name)
      n = n + 1
      if rec.order == units.IDLE and not a.member[un] and not (a.held and a.held[un]) and not divisions.of_unit(un)
         and rec.issuer ~= "market" then
        idle = idle + 1
      end
    end
  end
  return total, n, idle
end

local function clock(tick)
  local m = storage.match
  local s = (tick - m.tick_started) / 60
  return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
end

local function check(name, ok, text)
  util.log("r2debt check %s: %s %s", name, ok and "PASS" or "FAIL", text)
end

events.on_nth_tick(600, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local treasury = mod("treasury")
  local S = storage.r2debt
  if not S then
    S = {}
    storage.r2debt = S
  end
  local t = (game.tick - m.tick_started) / 3600
  if not S.force then
    if t < DEBT_AT then return end
    local best, bs
    local fs = {}
    for f in pairs(storage.ai or {}) do fs[#fs + 1] = f end
    table.sort(fs)
    for _, f in ipairs(fs) do
      local s = army(f)
      if not bs or s > bs then best, bs = f, s end
    end
    if not best then return end
    S.force, S.start = best, game.tick
    local s, n, idle = army(best)
    util.log("r2debt: %s put into debt at %s (balance %.0f -> %d): army supply %d, %d units, %d idle", best,
      clock(game.tick), treasury.balance(best), BALANCE, s, n, idle)
  end
  local f = S.force
  local held = game.tick - S.start <= HOLD_MIN * 3600
  if held and treasury.balance(f) > BALANCE / 2 then treasury.set_balance(f, BALANCE, "r2ai debt probe") end
  local s, n, idle = army(f)
  local stage = treasury.stage(f)
  if not S.t2 and stage >= 2 then
    S.t2, S.s2, S.n2 = game.tick, s, n
    check("debt_stage2", true, string.format("%s stage %d at %s, army supply %d (%d units, %d idle)", f, stage,
      clock(game.tick), s, n, idle))
  end
  if S.t2 and not S.after and game.tick - S.t2 >= 60 * 60 then S.after = n end -- the count once the first passes ran
  if S.after and held then S.max_after = math.max(S.max_after or 0, n) end
  if (game.tick - S.start) % 1800 < 600 and game.tick - S.start <= (HOLD_MIN + 4) * 3600 then
    util.log("r2debt: %s at %s: stage %d, balance %.0f, army supply %d, %d units, %d idle", f, clock(game.tick), stage,
      treasury.balance(f), s, n, idle)
  end
  if S.t2 and not S.checked and game.tick - S.t2 >= 3 * 3600 then
    S.checked = true
    check("debt_retire", s <= KEEP + 4 or idle == 0, string.format("%s 3 min after stage 2: army supply %d (was %d), "
      .. "%d units (were %d), %d idle; keep %d", f, s, S.s2, n, S.n2, idle, KEEP))
  end
  if S.after and not S.cap_checked and not held then
    S.cap_checked = true
    check("debt_cap", (S.max_after or 0) <= S.after, string.format("%s units after retiring %d, most during the hold %d",
      f, S.after, S.max_after or 0))
  end
  if not S.t2 and not S.fail_logged and game.tick - S.start > 5 * 3600 then
    S.fail_logged = true
    check("debt_stage2", false, f .. " never reached stage 2")
  end
end)
