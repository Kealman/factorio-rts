# Release 0.1.4: r6-ai notes (#39 AI copper in Age I, #2 rail linking), wave 2

Date: 2026-11-01. Agent: `r6-ai`. Branch `worktree-agent-abb28e3d9a0683985` from `main` 3abff7b (0.1.4 development build
2 + the wave 2 plan; it holds r5-rails' crew fix 84464c8 and #44 49604d8). Engine Factorio 2.1.24 (Steam, mac-arm64),
Space Age on. Plan: `docs/qa/release-0-1-4-plan.md` sections 3 and 5 (rules of the 0.1.2 and 0.1.3 plans). Wave 1 notes:
`docs/qa/release-0-1-4-r5-ai-notes.md` (r5-ai; its levers L1, L2s, L3 and L1b are retested here). Everything here is
Nation-only; Skirmish runs exactly as before.

## 1. Summary

Shipped (the coordinator's decision of 2026-11-01): the full stack, three commits.

| Commit | Lever | Change |
|---|---|---|
| 5ec35d1 | L1 | the governor's "copper runs short" rule queues a copper hub slot with every copper extractor (`balance.nation.people.ai.copper_drills_per_slot = 1`; it took two per slot) |
| bb95e4a | L2s | an AI rail program whose escrow has been short for 2 minutes in one phase pays on above a one-kit minimum (10 iron, 2 copper, 2 circuits, 5 steel) instead of above the reserve plus the floor; not while the paying city was attacked in the last 60 s (`balance.nation.rails.ai_escrow_patience`, `ai_escrow_min`, `ai_escrow_calm`) |
| d0a4737 | L3 | the planner's Age I circuit hold on trunk edges ends once rails.lua's own line is open (`balance.nation.ai3.planner.trunk.age1_after_main = true`) |

| Criterion (plan section 5) | 0.1.3 acceptance | base 3abff7b | shipped (L1 + L2s + L3) | Result |
|---|---|---|---|---|
| capitals lost | 0 | 0 | 0 | kept |
| capital starving minutes | 0 | 0 | 0 | kept |
| capital iron / copper <= 10, minutes 10-35 (within ~10 %) | 318 / 242 | 318 / 242 | 346 / 208 (+8.8 % / -14 %) | kept |
| army at 35:00 (within ~10 %) | 724 | 724 | 907 (+25 %) | kept (larger) |
| M1 501 score; train items (≥ 53/53; ≥ 25,000) | 53/53; 25,678 | 53/53; 25,678 | 53/53; 28,353 | kept |
| Age III by 40:00 (≥ 4 of 5) | 5/5 | 5/5 | 4/5 (801 at 40:52) | kept |
| M3 train items (not below by more than ~10 %) | 211,568 | 213,347 | 240,012 (+12.5 %) | kept |
| target: aggressive first line before 32:00 (4 of 5) | 3/5 | 3/5 | **5/5** (23:00-29:48) | **met** |
| target: nations linked by 35:00 (16 of 20) | 12/20 | 12/20 | 12/20 | **not met** (section 6) |

#39 (Age I copper): the copper part is done: copper is no longer what the rail programs wait for (copper
program-minutes to 35:00 240 -> 74), and L1 and L2s act for every doctrine, the aggressive and turtle ones included. Its
second part (one steel smelter kept fed) joins the steel lever of section 6. #2: the aggressive AI's first line is met
(5 of 5); linking three cities by 35:00 is not (12 of 20): the programs now wait for steel (section 6).

## 2. Method

- **Trees.** Every measured tree is a frozen full copy of the mod (`build/r6ai-trees/<tag>/factorio-rts` in this
  worktree, with `STATUS`): `base` = 3abff7b; `l1` = + L1; `l2s` = L1 + L2s; `l3` = L1 + L2s + L3 (= the shipped head,
  file for file); `l1b` = l3 + L1b; `f1` = l3 + the dry-extractor fix (section 5); `l3c` = l3 + r6-rails' c671b64 alone.
  Each commit is the frozen tree it was measured on (files copied from it).
- **Runs.** M1 501 (1v1, 2048, 60 min, `tools/probes/m1_acceptance.lua`) and M3 801-805 (4 normal AIs, 2048, 60 min,
  `tools/probes/m3_acceptance.lua`), SPEED 8, PERF=1, the last 5 minutes at speed 1: the commands of
  `tools/release-check.sh` stages m1 and m3, with r5-ai's read-only probes (`r5ai_m1.lua`, `r5ai_m3.lua`: the acceptance
  probes plus the capital block, the rail-program block and the status block; copied unchanged to
  `scratchpad/r6-ai/probes/`). At most 3 servers of mine and never more than 5 on the machine (a run starts only while
  fewer than 5 run; the batch scripts take a shared slot lock; the lead's and r6-rails' matrices ran beside most
  batches, so speed-1 minutes are upper bounds).
- **Tools** (session scratchpad `r6-ai/`): r5-ai's `batch.sh`, `checks.sh`, `mktree.sh`, `owner-load.sh`, `compact.py`,
  `diag.py`, `misses.py`, `bydoc.py`, `samelines.py` pointed at this worktree; new: `batch2.sh` (counts the map-creation
  process too), `batch3.sh` (counts the matrix runs too, section 7), `checks2.sh` (`ONLY=` a subset of the matrix),
  `perseed.py` (per-seed capital figures), `luacheck.py` (compiles Lua with lupa's Lua 5.2: a syntax and local-limit
  check without the game), `probes/lines_block.lua` (per line: extractors built, dry, free spots; written for section 5,
  not used in the batches). Each tree's batch writes `build/r6ai-rc/<tag>/REPORT.md` with `tools/release-check.py`.
- **A load failure caught before the runs.** `scripts/rails.lua`'s main chunk stands at 198 of Lua's 200 locals on this
  base (the 0.1.4 rails work added many); r5-ai's L2s patch added three top-level `local function`s and would not have
  loaded ("too many local variables (limit is 200) in main function"). The three helpers are one local table
  (`escrow.waived`, `escrow.short`, `escrow.paid`) in bb95e4a, so one local is left; r6-rails was told (its helpers go
  on `J` / `rails.`).

## 3. The base (3abff7b) against the 0.1.3 acceptance

| Number | 0.1.3 acceptance (`build/release-check/2026-10-28_0145`; capital figures from r5-ai's probe runs of that tree) | base 3abff7b |
|---|---|---|
| M1 501 checks; train items; rts-ai-1 Age II | 53/53; 25,678; 19:57 | 53/53; 25,678; 19:57 (game lines identical up to the summary) |
| Age III by 40:00 (first per seed) | 5/5 (36:59 38:03 38:02 37:56 37:26) | 5/5 (the same minutes) |
| nations linked by 35:00 | 12/20 (2, 4, 2, 3, 1) | 12/20 (2, 4, 2, 3, 1) |
| aggressive first line before 32:00 | 3/5 (28:57 34:13 28:35 25:56 32:08) | 3/5 (the same) |
| capital iron / copper lows; starving minutes; capitals lost | 318 / 242; 0; 0 | 318 / 242; 0; 0 |
| army at 35:00 / 60:00; units lost; capital-attacked minutes | 724 / 1041; 1815; 43 | 724 / 987; 1819; 43 |
| M3 train items | 211,568 | 213,347 |
| speed-1 minutes max; Lua errors | 60.0 s; 0 | 60.3 s; 0 |

802-805 are line-identical to 0.1.3 up to the summary (803 but for one "waits for a construction train: busy" line that
the busy rule of 84464c8 no longer writes). 801 diverges at minute 39, where crew 153 "stands against another train" and
now goes home after 15 s: from there 801's war and freight differ (its train items 54,505 -> 56,284, army at 60:00
lower). So the 0.1.4 rails work changed none of the AI's acceptance numbers; r5-rails' measurement of 84464c8 (its notes
section 8) says the same. Rail-program wait budget to 35:00 (program-minutes short of an item, `diag.py`): steel 384,
iron 280, copper 240, circuits 67, trunk edges held 216: r5-ai's 0.1.3 figures exactly.

## 4. The levers, one at a time

First Age III / nations linked at 35:00 / the aggressive AI's first line, per seed:

| seed | base | L1 | L1 + L2s | L1 + L2s + L3 (shipped) |
|---|---|---|---|---|
| 801 | 36:59 / 2 / 28:57 | 38:49 / 3 / 32:18 | 41:51 / 3 / 28:38 | 40:52 / 3 / 29:48 |
| 802 | 38:03 / 4 / 34:13 | 38:43 / 3 / 34:28 | 35:25 / 3 / 28:33 | 35:15 / 3 / 28:33 |
| 803 | 38:02 / 2 / 28:35 | 38:02 / 2 / 28:35 | 39:01 / 4 / 23:00 | 39:36 / 3 / 23:00 |
| 804 | 37:56 / 3 / 25:56 | 35:46 / 3 / 25:47 | 33:54 / 1 / 24:06 | 33:54 / 1 / 24:06 |
| 805 | 37:26 / 1 / 32:08 | 45:04 / 2 / 31:32 | 37:48 / 2 / 26:42 | 38:29 / 2 / 26:42 |

| 801-805 | base | L1 | L1 + L2s | L1 + L2s + L3 (shipped) |
|---|---|---|---|---|
| Age III by 40:00 | 5/5 | 4/5 | 4/5 | 4/5 |
| nations linked at 35:00 | 12/20 | 13/20 | 13/20 | 12/20 |
| linked per doctrine (aggressive, economic, turtle) | 1/5, 11/14, 0/1 | 1/5, 12/14, 0/1 | 1/5, 12/14, 0/1 | 1/5, 11/14, 0/1 |
| aggressive first line < 32:00 | 3/5 | 3/5 | 5/5 | 5/5 |
| lines open at 60:00 | 61 | 66 | 66 | 67 |
| items by train | 213,347 | 205,678 | 252,574 | 240,012 |
| capital iron / copper <= 10 (minutes 10-35, 20 nations) | 318 / 242 | 348 / 188 | 347 / 212 | 346 / 208 |
| capital starving minutes | 0 | 1 | 0 | 0 |
| army units at 35:00 / 60:00 | 724 / 987 | 887 / 1104 | 865 / 1143 | 907 / 1138 |
| army units lost by 60:00 | 1819 | 1696 | 1898 | 2080 |
| capital-attacked minutes | 43 | 43 | 22 | 36 |
| cities lost to nations (capitals) | 19 (0) | 13 (0) | 20 (0) | 22 (0) |
| release check: M2 criteria; nations with an operation | 5/5; 20/20 | 5/5; 20/20 | 5/5; **19/20** | 5/5; 20/20 |
| rail wait to 35:00: steel / iron / copper / circuits; edges held | 384 / 280 / 240 / 67; 216 | - | 505 / 204 / 47 / 40; 285 | 566 / 218 / 74 / 45; 238 |
| speed-1 minutes, max; Lua errors | 60.3 s; 0 | 60.0 s; 0 | 60.0 s; 0 | 60.0 s; 0 |

| M1 501 | base | L1 | L1 + L2s | L1 + L2s + L3 (shipped) |
|---|---|---|---|---|
| score | 53/53 | 53/53 | 53/53 | 53/53 |
| train items (player + rts-ai-1) | 25,678 (14,196 + 11,482) | 26,841 (13,957 + 12,884) | 28,353 (14,732 + 13,621) | 28,353 (line-identical to L1 + L2s) |
| rts-ai-1 Age II | 19:57 | 15:50 | 19:14 | 19:14 |
| army at 35:00 / 60:00; units lost; capital-attacked minutes | 58 / 85; 293; 13 | 36 / 119; 181; 6 | 60 / 88; 196; 10 | the same |
| cities lost; speed-1 minutes max | 0; 60.0 s | 0; 60.0 s | 0; 60.0 s | 0; 60.0 s |

Per seed (capital iron / copper-low minutes; army at 35:00; train items):

| seed | base | L1 | L1 + L2s | shipped |
|---|---|---|---|---|
| 801 | 66 / 63; 124; 56,284 | 57 / 47; 201; 57,508 | 54 / 62; 165; 66,589 | 56 / 60; 158; 60,766 |
| 802 | 74 / 22; 152; 34,683 | 80 / 21; 151; 43,204 | 71 / 33; 193; 44,320 | 71 / 33; 177; 45,293 |
| 803 | 57 / 69; 177; 40,680 | 57 / 69; 177; 40,680 | 57 / 60; 145; 52,390 | 58 / 60; 159; 50,643 |
| 804 | 49 / 55; 95; 40,600 | 85 / 18; 177; 23,962 | 89 / 20; 179; 32,660 | 89 / 20; 179; 32,660 |
| 805 | 72 / 33; 176; 41,100 | 69 / 33; 181; 40,324 | 76 / 37; 183; 56,615 | 72 / 35; 234; 50,650 |

Reading:
- **L1** (5ec35d1) is r5-ai's 1f4b525 unchanged; on this base it reproduces r5-ai's M1 run exactly (26,841) and 803
  stays line-identical to the base (the governor never fires before the opening's step there). Alone it moves #2 by one
  nation, costs 3.6 % of the freight and one Age III, and one capital ration dip (804 rts-ai-3, one minute at 55:00
  while attacked). It is the base of L2s (without it M1's rts-ai-1 reached Age II after the 20:30 check in wave 1).
- **L2s** (bb95e4a) is the lever: the aggressive first line 3 -> 5 of 5, freight +23 % over L1, copper stops being a
  rail wait (240 -> 47 program-minutes), capital-attacked minutes halve. The wave-1 blockers are gone: M1 501 53/53 with
  28,353 train items (wave 1: 52/53, 19,461, behind a crew stuck "on_the_path"), and no capital lost (wave 1 lost 801
  rts-ai-1 at 46:00; here 801 diverges from wave 1 at minute 24, where crew 60 "stands against another train" and goes
  home after 15 s, and its rts-ai-1 holds). 805's turtle starts no operation by 60:00 (base: its first at 50:00), which
  drops the release check's "nations that ran an operation" row to 19/20 (the same 805 game as wave 1's L2s: 93
  differing lines).
- **L3** (d0a4737) acts on 801, 802, 803 and 805 (804 and M1 line-identical to L2s). Every number is within one nation
  of L2s; it keeps the operations row at 20/20, so the stack keeps every release-check row the base passes except Age
  III 5 -> 4 of 5 (that row's target is 3; the plan's is 4). The coordinator chose the full stack.
- The economic nations are the linked ones either way (11-12 of 14); the aggressive AI links three cities in 1 of 5
  seeds on every tree.

## 5. Measured and not shipped

| Lever | Tree | Result | Why not |
|---|---|---|---|
| L1b: the copper bootstrap (the copper line's parts first, its plates kept from make targets, goods and workshops while the capital holds under 40) lasts until the line has two hub slots (r5-ai's `l1b-build_order.patch` + `copper_boot_slots = 2`) | `l1b` = shipped + L1b | M1 501 **50/53**: Age II of rts-player 22:03 and rts-ai-1 25:18 (both past 20:30), rts-player no armoured car; 30,095 train items | fails M1; the M3 batch was stopped after M1 |
| F1: the governor removes a dry extractor (status `no_minable_resources`) of the capital's lines while the line has a free drill spot, and the build order takes that spot (`ai/governor.lua` `retire_dry`, key `retire_dry`) | `f1` = shipped + F1 | it acts from minute 14 (801: 10 iron, 4 town1, 2 hub1, 1 coal extractors across the 4 nations); M1 501 **52/53** (cars_rts-player: no armoured car), 34,358 train items; 801: linked 1 (shipped 3), iron-low minutes 56 -> 71; 802: 71 -> 81, freight -8 % | fails M1 and helps no number it was meant for; the batch was stopped after 802 |

F1 is the first of r5-ai's three follow-ups (section 7 of its notes):
- **Dry iron extractors never replaced.** True and measured above: capital iron lines run dry from minute 14 (the ore
  patches near the capitals are small), each dry extractor stays "built" for the build order and keeps 4 jobs. Replacing
  them (F1) costs the plates of a new extractor at the moment iron is shortest and did not lift the capitals' iron
  (iron-low minutes 801: 56 -> 71, 802: 71 -> 81); it is not the cheap fix it looked like. Not shipped; patch kept
  (`scratchpad/r6-ai/f1.patch`).
- **The capital labour deadlock at goods 0 %.** Not seen on the shipped tree: capital-minutes (10-60) at goods 0 % with
  fewer workers than jobs (`goods0.py`, from the "people minute" lines) 47 on the base (longest stretch 8 minutes, 801
  rts-player to 34:00), 56 on the shipped tree (longest 3 minutes); wave 1's 23-minute stretch (801 rts-ai-1 on L2
  without a minimum) does not occur. The fix (the goods works ahead of the services in the labour order, or a pin on the
  first one) is a labour-model change with a full measurement of its own, not a cheap bug fix. Not changed.
- **Ports' starting steel sold at minutes 2-4.** Not a bug: the port lies about 800 tiles out, beyond the planner's
  port_reach and any route home, so the stock cannot reach the capital; the market AI turns it into about 1,200 credits
  by minute 5 and buys from minute 6 (801 rts-ai-1: sold 1,183 cr in 4 sales, then imports). Not changed.

## 6. Linked 12 of 20: steel is the next wait (issue text for #2)

With the escrow paying on after a wait, the rail programs stop waiting for copper and iron and wait for steel:
program-minutes short of an item to 35:00, base -> shipped: steel 384 -> 566, iron 280 -> 218, copper 240 -> 74,
circuits 67 -> 45 (trunk edges held 216 -> 238). Most nations of the shipped tree wait 21-46 program-minutes for steel.
Example, 804 rts-ai-1 (aggressive, linked at 56:00): its main line opened at 24:06, then both trunk edges stood in
"depots" from 24:00 past 35:00 with escrows {depot: copper 10/10, iron 40/40, steel 3-4/10} while the capital held 0-6
steel: one steel chain (19 a minute) feeds the heavies, the depots, the locomotive kits (10 steel each) and the Charter.
The misses at 35:00 on the shipped tree are 4 aggressive nations (linked at 36, 47, 38 and 56 minutes), the 805 turtle
(47) and three economic nations (44, 37, 36): four of the eight link by 38:00.

Proposed next lever (for #2): a second steel chain in Age I for a nation whose rail programs have waited for steel for a
few minutes (the build order's Age I steel is one smelter slot, about 19 plates a minute), or steel kept from the
barracks' heavies while a depot or crew kit of an open line's edge waits for it (the barracks already save for the
rails' iron). The measure stays: linked by 35:00 ≥ 16 of 20 with the shipped tree's guard numbers (no capital lost,
starving 0, capital lows and army within ~10 %, M1 501 ≥ 53/53 and ≥ 25,000, Age III ≥ 4/5, M3 freight not below 0.1.3
by more than ~10 %).

## 7. Checks on the shipped tree (L1 + L2s + L3 = d0a4737, frozen tree `build/r6ai-trees/l3`)

| Check | Command | Result |
|---|---|---|
| Skirmish smoke | `KEEP_TREE=<tree> SEED=9090 tools/autotest-run.sh r6ai-<tag>-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` on `base`, `l1`, `l2s`, `l3` | 65/65 each, 0 errors; l1, l2s and l3 line-identical to the base tree's smoke (481 lines); the base smoke equals the 0.1.3 release smoke but for one trailing "spawned" line |
| Skirmish identity | the ten scenarios of `tools/autotest-matrix.sh` with `SEED=777 KEEP_TREE=build/r6ai-trees/l3/factorio-rts`, one server each (`scratchpad/r6-ai/checks.sh`, `checks2.sh`), then `tools/matrix-compare.sh base0111 r6ai-l3` | **0 differing lines** in all ten (1,235-4,858 lines each); summaries as the 0.1.1 baseline (stress 36/38 as there); 0 Lua errors |
| M1 501, M3 801-805 | section 4 | 0 Lua errors; speed-1 minutes max 60.0 s (M1 and M3) |
| Owner save 0.1.4 dev | `owner-0114-now.zip` (copy), 120 s headless on the tree (`scratchpad/r6-ai/owner-load.sh`) | loads, 597 `[rts]` lines, the match runs on (minutes 100-101), 0 errors, nothing reset |
| Owner save 0.1.3 | `owner-0113-now.zip` (copy), 120 s | loads, 733 `[rts]` lines, minutes 85-86, 0 errors, nothing reset |
| Owner save 0.1.2 | `owner-0112.zip` (copy), 120 s | loads, 690 `[rts]` lines, minutes 55-56, 0 errors, nothing reset |
| Owner save 0.1.1 Age II | `owner-0111-age2.zip` (copy), 120 s | loads, 744 `[rts]` lines, minutes 116-117, 0 errors, nothing reset |
| War paths | `tools/probes/ai3_war_paths.lua`, seed 811, 1v1 hard, SPEED 10 | 6/6 (mercenaries, hire_garrison, interceptors, holding_division, bombers, artillery_train), 0 errors |
| Lua load check | `scratchpad/r6-ai/luacheck.py` (lupa, Lua 5.2) on every changed file of every tree | compiles; rails.lua at 199 of 200 main-chunk locals |
| M1 determinism (SPEED 8 and 10 pair) | not run | no lever has a random input; the release check runs the pair |

Storage: L2s adds two fields to an AI rail program's own table (`A.wait_phase`, `A.wait_since`), created when first
needed; L1 and L3 read balance keys only. Old saves load as before (above); the owner saves' AI forces resume their
programs with no wait recorded.

Machine budget: at most 3 servers of mine, with one exception: for about 2 minutes at 20:14 a Skirmish matrix run and
three M3 runs of mine ran together (my `batch2.sh` counted only `build/r6ai-*` runs, not `build/mx-r6ai-*`; the machine
stood at 5, never more). The fourth run was stopped and rerun; `batch3.sh` counts both.

## 8. The shipped stack with r6-rails' c671b64 (separate column)

r6-rails' c671b64 (an AI freight train stranded on a given-up line is scrapped after AI_FREIGHT_STUCK; Refs #33) is
AI-visible and the coordinator merges r6-rails first, so the shipped stack was measured with it, cherry-picked alone
(not r6-rails' other commits; tree `l3c`):

| 801-805 + M1 501 | shipped (l3) | shipped + c671b64 (l3c) |
|---|---|---|
| Age III by 40:00; linked at 35:00; aggressive first line | 4/5; 12/20; 5/5 | 4/5; 12/20; 5/5 (every per-seed minute the same) |
| items by train; lines open at 60:00 | 240,012; 67 | 240,139; 66 |
| capital iron / copper lows; starving minutes; capitals lost | 346 / 208; 0; 0 | 346 / 208; 0; 0 |
| army at 35:00 / 60:00; units lost; capital-attacked minutes | 907 / 1138; 2080; 36 | 907 / 1215; 1949; 35 |
| release check rows (M2 criteria, operations, founds, speed-1) | 5/5, 20/20, 20/20, 60.0 s | 5/5, 20/20, 20/20 (804 rts-ai-1 ends with 2 cities after conquests), 60.0 s |
| M1 501 | 53/53; 28,353 | 53/53; 28,353 |

M1 501, 801, 802 and 805 are line-identical to the shipped tree up to the summary (c671b64 never fires there; on the
base r6-rails saw it act on 802 and 805, but the levers change those games long before); 803 and 804 diverge where it
first scraps a stranded freight train (803 rts-ai-3's train 107 at minute 39, 804 rts-player's train 29 at minute 32),
after the 35:00 measurements. Every criterion holds with c671b64.

## 9. Proposed changelog lines

```
AI (Nation):
  - AI capitals short of copper build a copper smelter with each new copper extractor, so their copper reaches two
    smelters' output earlier in Age I.
  - An AI rail program that has waited 2 minutes for its depots or train kits pays on from its capital's spare
    plates (it keeps one unit kit of each kind, and waits while the capital is under attack): the aggressive AI opens
    its first line before 32:00 in every test seed (was 3 of 5), and about 12 % more goods move by train.
  - The AI's trunk lines no longer wait for 40 circuits in Age I once its first line is open.
```
