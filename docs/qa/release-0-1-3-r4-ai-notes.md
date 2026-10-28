# Release 0.1.3: r4-ai notes (#20 AI follow-ups, #2 aggressive AI rail linking)

Date: 2026-10-27/28. Agent: `r4-ai`. Branch `worktree-agent-a122778c8968846f1` from `main` 684c069 (0.1.2 + the 0.1.3
plan). Engine Factorio 2.1.23 (Steam, mac-arm64), Space Age on. Plan: `docs/qa/release-0-1-3-plan.md` (rules of
`docs/qa/release-0-1-2-plan.md` section 3). Everything here is Nation-only; Skirmish runs exactly as before.

## 1. Summary

| Issue | Target | 0.1.2 | Shipped (17a405d) | Status |
|---|---|---|---|---|
| #20 (2) Industrialisation wanted in Age I; the aggressive AI's Age II deadline | M1 501 all checks | 51/53 (Age II 32:36) | **53/53** (Age II 19:57) | met |
| #20 (1) siege kits at plan time | kits requested when the siege railway is planned | at line under way, capital lines only | from plan time, any origin city, moved to the line's depot | done; no siege line reached that point in the runs |
| #20 (3) lost-line depot rebuild under the engine focus | not held | held | not held | done |
| #20 (4) army.step pool passes on the scheduler | optional, perf margin | scene 20 ticks over 3 ms (limit 60) | not done: no margin needed | open, low priority |
| #7 train items (M1 501) | ≥ 20,000 | 19,101 | **25,678** | met (one seed, war-sensitive) |
| #1 Age III by 40:00 | ≥ 3/5 | 2/5 | **5/5** | met |
| #2 nations linked by 35:00 | ≥ 16/20 | 9/20 | **12/20** (13/20 on L1+L2 alone) | **not met** |
| #2 aggressive first line < 32:00 | ≥ 4/5 | 4/5 | 3/5 (805 at 32:08, 802 at 34:13) | at the noise edge |

Commits (all "AI 0.1.3: ..."): d0eabd2 (#20 items 1 and 3), 75244f9 (Industrialisation, then Railways first),
54ab827 (coal extraction), fd41233 (freight train recovery), ac304fe (siege kits from a town), 17a405d (engine focus
and the third city's edge). Measured but not shipped: L3 (rail escrow floor) and L7 (copper hub for the aggressive and
turtle doctrines), section 4.

## 2. Method

- **Trees.** Every measured tree is a frozen copy (`build/r4ai-trees/<tag>/factorio-rts`): the 0.1.2 tree with the
  lever's files copied over, so a commit's numbers are exactly the committed code. Tags: `base`, `basep`, `base2` =
  684c069 (0.1.2); `l2p` = L1 + L2 (= 75244f9); `l3q` = + L3 (dropped); `l46n` = L1 + L2 + L1b + L4 + L5 + L6
  (= 17a405d, verified file by file); `l7` = + L7 (dropped). Discarded drafts: `l2` (Industrialisation preempting the
  opening techs), `l2r` (Railways not protected), `l46` (with L3).
- **Runs.** M1 501 (1v1, 2048, 60 min, `tools/probes/m1_acceptance.lua`) and M3 801-805 (4 normal AIs, 2048, 60 min,
  `tools/probes/m3_acceptance.lua`), SPEED 8, PERF=1, the last 5 minutes at speed 1: the commands of
  `tools/release-check.sh` stages m1 and m3. At most 3 servers of mine and never 5 or more on the machine; some
  batches ran beside the lead's matrix, so their speed-1 minutes are upper bounds.
- **Capital probe.** The acceptance probes plus an observing block (session scratchpad `r4-ai/probes/r4ai_m3.lua`,
  `r4ai_m1.lua`): every second the capital network's iron and copper (lowest per minute), every minute the capital's
  ration share and starving minutes (below half), the army size, the army units gone so far and the minutes the
  capital was attacked (`cities.under_attack`). It only reads: the 0.1.2 tree with it is line-identical to the tree
  without it in every game line (the probe's own timestamps move by up to a second).
- **Noise.** The 0.1.2 tree reproduces the 0.1.2 release check line for line (68,718 `[rts]` lines in M1 501, 140,795
  in 802, 0 differing), so an unchanged tree has no run-to-run noise; any change perturbs the match from about minute
  3, and wars and captures then reshuffle. Five seeds separate levers only roughly; mechanism figures (research times,
  depot placement, line waits) carry the attribution.
- **Tools** (session scratchpad `r4-ai/`): `batch2.sh` (runs and slot discipline), `compact.py` (the tables below),
  `metrics.py` (per nation: research, ages, depots, lines, waits, capital figures), `railtl.py` (per-nation rail
  timeline), `waits.py` (line wait budget), `econ.py` (per-minute economy of one force).

## 3. Baseline: what holds the lines (0.1.2 tree)

- **Line waits before 35:00** (801-805, line-minutes): crews waiting for kits 155, for rails 84, for coal 7; a
  program's two depots took 3-18 minutes from its start to its survey (the escrow floors met capitals holding 0-60
  iron or 0-30 copper); over the whole hour (with M1 501) crews waited 308 line-minutes for coal.
- **The aggressive AI** finished Industrialisation at 14:40-23:25 and reached Age II at 17:22-32:35: the supply cap
  put Supply 2 first (801: 7:00-14:05, labs starved of advanced kits), and the Charter's 100 steel competed with its
  rail crafts. Its depots and crew kits waited for Railways (the works factory's recipes) and for copper (one copper
  slot, 37-38 copper a minute, until minute 20-25).
- **Rails side (#33, r4-rails):** AI construction crews stuck "on_the_path" (801 rts-ai-3 line #2 at (-655, 7.8),
  three crews, the line never opened; 804: 9 events; reported to r4-rails), and, seen later in my runs, depot platforms
  flipping "busy"/"no-kits" for minutes when two depots of one capital stand side by side (803, 805).

## 4. Levers

| Lever | Change | Files | Result | Shipped |
|---|---|---|---|---|
| L1 | #20 (3): a trunk line in state "lost" is not held by the engine focus; #20 (1): artillery kits wanted from the siege railway's plan time | planner.lua, council.lua | measured with L2 | yes (d0eabd2) |
| L2 | Industrialisation, then Railways, take the labs from any running technology once their kit can be made and the opening's two techs are done (supply cap and wanted war techs included) | tech.lua | aggressive AI Industrialisation 14:40-23:25 -> 13:50-19:40, Age II 17:22-32:35 -> 19:23-22:55; M1 53/53; Age III 5/5; linked 9 -> 13 | yes (75244f9) |
| L3 | rail escrow floor waived (iron, copper, circuits; steel in Age I) while the barracks save, never below `balance.nation.ai3.rail_escrow_min` 40/20/10/10 | rails.lua, balance.lua | no target moved (linked 12, aggressive 3/5, M1 train items 17,554); the waits are for copper or steel below the minimum, not floor-blocked iron | **no** |
| L4 | one more coal extractor below `balance.nation.people.ai.coal_low` (100) coal | governor.lua, balance.lua | crews' coal waits over 60 min 206 -> 9 line-minutes; lines open by 60:00 60 -> 74 | yes (54ab827) |
| L5 | an AI freight train that lost a locomotive or has had no path for 3 min is scrapped (half its kits back) and rebuilt | rails.lua (ai_program) | 2 trains replaced in 801-805 | yes (fd41233) |
| L1b | artillery kits for siege railways from any own city, moved to the line's depot; no deploy try at the forward depot before its line opens | council.lua | no siege line reached the forwarding point in these runs | yes (ac304fe) |
| L6 | the engine focus does not hold the edge that joins a third city to the capital while fewer than three are joined | planner.lua | no separate effect visible; Age III stays 5/5 | yes (17a405d) |
| L7 | the aggressive and turtle doctrines build the economic doctrine's copper hub (hub 2) after their steps, from 7:00 | orders_data.lua (Nation order only) | the step came last in the order and started at 20:44 in M1 501 (train items 14,758); stopped after M1 | **no**: 0.1.4 |

Rules kept: no item is created for the AI (every lever spends its own goods, research time or build order), the
Skirmish paths are unchanged (every branch is behind Nation-mode checks, the smoke and the matrix below), the 0.1.1
army floors are untouched (`min_army` 20 for the Charter, the town and districts; the home guard), and no capital
was taken below its reserve: capital starving minutes 0 in every run.

## 5. Results

First Age III / nations linked at 35:00 / the aggressive AI's first line, per seed:

| seed | 0.1.2 (base2) | L1+L2 (l2p) | +L3 (l3q, dropped) | shipped (l46n) |
|---|---|---|---|---|
| 801 | 38:15 / 1 / 31:27 | 38:46 / 3 / 28:41 | 39:06 / 3 / 26:14 | 36:59 / 2 / 28:57 |
| 802 | 34:42 / 2 / 29:00 | 36:17 / 3 / 40:08 | 35:41 / 4 / 30:38 | 38:03 / 4 / 34:13 |
| 803 | 41:16 / 2 / 26:14 | 36:03 / 2 / 28:25 | 39:16 / 2 / 37:31 | 38:02 / 2 / 28:35 |
| 804 | 41:36 / 2 / 16:26 | 38:27 / 2 / 25:56 | 39:14 / 1 / 49:37 | 37:56 / 3 / 25:56 |
| 805 | 41:13 / 2 / 42:58 | 37:26 / 3 / 27:39 | 35:06 / 2 / 28:32 | 37:26 / 1 / 32:08 |

| 801-805 | 0.1.2 | L1+L2 | +L3 (dropped) | shipped |
|---|---|---|---|---|
| Age III by 40:00 | 2/5 | 5/5 | 5/5 | **5/5** |
| nations linked at 35:00 | 9/20 | 13/20 | 12/20 | **12/20** |
| aggressive first line < 32:00 | 4/5 | 4/5 | 3/5 | 3/5 |
| items by train | 175,999 | 205,413 | 214,708 | 211,568 |
| lines opened by 60:00 | 52 | 60 | - | 74 |
| crews waiting for coal over 60 min (line-minutes, with M1) | 308 | 206 | - | 9 |
| capital iron / copper <= 10 (minutes 10-35, 20 nations) | 306 / 221 | 310 / 241 | 334 / 243 | 314 / 241 |
| capital starving minutes | 0 | 0 | 0 | 0 |
| army units at 35:00 / 60:00 | 820 / 1373 | 778 / 1259 | 920 / 1068 | 725 / 1041 |
| army units lost by 60:00 | 1820 | (probe without it) | 2225 | 1815 |
| capital-attacked minutes | 22 | (probe without it) | 27 | 42 |
| cities lost to nations (capitals) | 18 (0) | 21 (0) | 20 (0) | 19 (0) |
| seeds with a starving nation | 1 | 0 | - | - |
| speed-1 minutes, max | 60.2 s | 60.1 s | - | 60.3 s |
| Lua errors | 0 | 0 | 0 | 0 |

| M1 501 | 0.1.2 | L1+L2 | +L3 (dropped) | shipped |
|---|---|---|---|---|
| score | 51/53 | 53/53 | 52/53 | **53/53** |
| train items (player + rts-ai-1) | 19,101 (10,881 + 8,220) | 20,999 (11,258 + 9,741) | 17,554 (9,440 + 8,114) | **25,678** (14,196 + 11,482) |
| rts-ai-1 Age II | 32:36 | 19:57 | 20:21 | 19:57 |
| failed checks | age2_rts-ai-1, train_items | none | train_items | none |
| army at 35:00 / 60:00 | 146 / 126 | 64 / 106 | 56 / 77 | 58 / 85 |
| units lost, capital-attacked minutes | 237, 8 | - | 231, 9 | 293, 13 |
| cities lost | 0 | 1 (a captured city-state, 56:00) | 0 | 0 |
| speed-1 minutes, max | 60.0 s | 60.1 s | - | 60.0 s |

Reading the guard figures:
- **The capitals are not emptier.** The minutes with the capital's iron or copper at 10 or less move within a few
  per cent; starving minutes stay 0.
- **The armies are smaller** at 35:00 (820 -> 725 units over 20 nations; M1 146 -> 58). Units lost by 60:00 are the
  same as on 0.1.2 (1815 against 1820).
- **The capitals are attacked more** (22 -> 42 minutes), mostly the aggressive AI's own capital (5-7 minutes a seed).
  That AI declares war the minute it reaches Age II, so with Age II at about 20:00 instead of 26-32 its wars start
  earlier and the counter-attacks reach it.
- **No capital fell in any run.** The cities that changed hands are towns and captured city-states, reshuffled between
  nations without a trend. The new losses on L1+L2 come 30-40 minutes after the lever acts (801 and 802 rts-ai-1's
  towns at 55:00 and 60:00, 805 rts-ai-3 at 49:00); the lead decided on no cap.

## 6. Checks on the shipped tree (17a405d = l46n)

| Check | Command | Result |
|---|---|---|
| Skirmish smoke | `KEEP_TREE=<l46n> SEED=9090 tools/autotest-run.sh r4ai-l46n-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65, 0 errors, line-identical to the 0.1.2 release smoke (468 lines); the same on the L1+L2 tree |
| Skirmish identity | `SEED=777 JOBS=2 KEEP_TREE=<l46n> tools/autotest-matrix.sh r4ai-l46n`, `tools/matrix-compare.sh base0111 r4ai-l46n` | 10 scenarios, 0 differing lines (the 0.1.1 baseline's summaries, stress 36/38 as there), 0 Lua errors |
| M1 determinism | M1 501 again at SPEED 10 (release-check stage m1's pair) | 70,776 `[rts]` lines, 0 differing from the SPEED 8 run; 53/53, 25,678 train items |
| Owner save 0.1.2 | `owner-0112.zip` (copy), 120 s headless on the tree (session scratchpad `r4-ai/owner-load.sh`) | loads, 664 `[rts]` lines, the match runs on (minutes 54-56), 0 errors, nothing reset |
| Owner save 0.1.1 Age II | `owner-0111-age2.zip` (copy), 120 s headless | loads, 739 `[rts]` lines, 0 errors, nothing reset |
| War paths | `tools/probes/ai3_war_paths.lua`, seed 811, 1v1 hard, SPEED 10 (release-check stage warpaths) | 6/6 (mercenaries, hire_garrison, interceptors, holding_division, bombers, artillery_train), 0 errors |

No storage structure changed (new fields are created lazily: `A.freight_stuck`, `S.kits_sent`), so old saves keep
loading as before.

## 7. Open (for 0.1.4)

- **#2 linking 12-13 of 20 against 16.** The remaining misses: the aggressive AI in 4 of 5 seeds; one economic nation
  per seed short of copper or held by a war; turtle 805. The binding constraint is Age I copper (one copper slot,
  37-38 a minute, for depots, crew kits and the Charter's circuits) and, after a lost battle, steel. L7 (a copper hub
  for the aggressive and turtle doctrines) is the candidate; placed at the end of the build order it came at 20:44,
  too late. Proposed issue: "AI copper in Age I: the aggressive and turtle doctrines build a copper hub (or copper
  extractors on the nearest patch) once their rail program waits for copper, and keep one steel smelter fed from the
  capital's reserve; measure linked by 35:00 and M1 501 train items".
- **Rails-side blockers (r4-rails, #33):** stuck crews ("on_the_path", 801 and 804), and depot platforms that flip
  "busy" for minutes next to another depot of the same capital (803, 805).
- **#20 (4)** army.step's pool passes on the scheduler: not needed for the perf limit (0.1.2 scene 20 script ticks over
  3 ms against 60); left open.
- **M1 501 is one seed and war-sensitive**: with the aggressive AI on time (Age II about 20:00) its war starts at
  Age II, and drafts of L2 gave 7,103-8,774 train items when that war broke the player's lines.

## 8. Proposed changelog lines

```
AI (Nation):
  - The aggressive AI researches Industrialisation, then Railways, before its army technologies: it reaches Age II
    around 20 minutes instead of 26-32.
  - AI capitals build another coal extractor when coal runs short, so rail crews and trains no longer stand without
    fuel.
  - An AI freight train that loses a locomotive or its path is taken apart and replaced.
  - Siege railways started from a town now get their artillery train.
  - The AI keeps building the rail line that links its third city while it waits for engines.
```
