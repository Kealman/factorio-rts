# Release 0.1.4: r5-ai notes (#39 AI copper in Age I, #2 rail linking)

Date: 2026-10-31. Agent: `r5-ai`. Branch `worktree-agent-a3e5c81a1af9b75c0` from `main` da0ec26 (release 0.1.3 + the 0.1.4
plan; mod tree = 61d6f05). Engine Factorio 2.1.23 (Steam, mac-arm64), Space Age on. Plan:
`docs/qa/release-0-1-4-plan.md` (rules of the 0.1.2 and 0.1.3 plans). Baseline: the 0.1.3 acceptance
`build/release-check/2026-10-28_0145/REPORT.md` in the main checkout. Everything here is Nation-only; Skirmish runs
exactly as before.

## 1. Summary

| Issue | Target (plan rule 3) | 0.1.3 | Shipped (L1, 1f4b525) | Best measured (L1 + L2, not shipped) | Status |
|---|---|---|---|---|---|
| #39 Age I copper: the second copper slot early | copper at two slots before the rail program waits | 9 of 20 capitals on one copper slot (37-38 a minute) past minute 15 | 5 of 20 | 6 of 20 | partly done |
| #2 nations linked by 35:00 | ≥ 16 of 20 | 12/20 | 13/20 | 15/20 (no minimum); 13/20 (calm gate, kit minimum) | not met |
| #2 aggressive first line < 32:00 | ≥ 4 of 5 | 3/5 | 3/5 | **5/5** (16:02-28:38) | not met with L1 alone |
| M1 501 (keep) | 53/53, 25,678 items | 53/53, 25,678 | **53/53, 26,841**; rts-ai-1 Age II 15:50 | 53/53, 25,503 (L2); 52/53, 19,461 (L2s) | kept |
| Age III by 40:00 (keep) | 5/5 | 5/5 | 4/5 (805 at 45:04) | 4/5 | one seed short (#1's target is ≥ 3) |
| no capital lost; starving minutes | 0; 0 | 0; 0 | 0; 0 | 0; 0 (L2); one capital lost (L2s) | kept on L1 |

Shipped: one commit, **1f4b525** "AI 0.1.4: a copper hub slot per copper extractor while copper runs short" (L1,
balance key `balance.nation.people.ai.copper_drills_per_slot`), plus a comment correction in the notes commit. The lever
that moves #2 is L2 (the rail escrow pays on after a wait). In its two shippable forms it either drained the capitals
(no minimum) or, with the coordinator's calm gate and kit minimum, lost one capital and M1's train items: a stuck
construction crew (the #33 crew bug that r5-rails fixed in 84464c8) stopped the player's freight. L2 and L3 stay
measured proposals (section 4; patch in the session scratchpad `r5-ai/l2s+l3-on-1f4b525.patch`), and the issue text
in section 7 asks for L2's retest on the merged tree.

## 2. Method

- **Trees.** Every measured tree is a frozen full copy of the mod (`build/r5ai-trees/<tag>/factorio-rts`, with `STATUS`
  and `DIFF`), so a commit's numbers are exactly the committed code. Tags: `base` = da0ec26 (0.1.3); `l1` = + L1
  (= 1f4b525); `l2` = L1 + L2 without a minimum; `l2only` = L2 alone; `l2m` = L1 + L2 with 0.1.3's minimum 40/20/10/10;
  `l2s` = L1 + L2 with the calm gate and the kit minimum; `l3` = L1 + L2 + L3.
- **Runs.** M1 501 (1v1, 2048, 60 min, `tools/probes/m1_acceptance.lua`) and M3 801-805 (4 normal AIs, 2048, 60 min,
  `tools/probes/m3_acceptance.lua`), SPEED 8, PERF=1, the last 5 minutes at speed 1: the commands of
  `tools/release-check.sh` stages m1 and m3. At most 3 servers of mine, started only while the machine had fewer than 5
  (other agents' matrices ran beside most batches, so speed-1 minutes are upper bounds).
- **Probes** (session scratchpad `r5-ai/probes/`, built by `r5-ai/mkprobes.py`): the acceptance probes plus r4-ai's
  capital block (capital iron/copper lows per minute, starving minutes, army, units lost, capital-attacked minutes) and
  two new read-only blocks: every minute to 45:00 per nation the rail programs' states and escrows (rails.lua's own
  program and each planner trunk edge), the capital's iron, copper, steel, circuits, stone and coal, the barracks' rail
  saving flag, the running research and the age (`[rts] r5ai rail minute N <force>: ...`); every 5 minutes the
  extractors and smelters by entity status (`[rts] r5ai status minute N <force>: ...`).
- **Tools** (session scratchpad `r5-ai/`): `batch.sh` (runs, slot discipline), `checks.sh` (matrix one scenario at a
  time, owner saves, war paths), `mktree.sh`, `samelines.py` (game-line identity of two logs), `compact.py` (the tables
  below), `misses.py` (nations not linked at 35:00), `bydoc.py` (linked per doctrine), `diag.py` (rail-program wait
  budget per resource from the probe lines).
- **Baseline reproduced.** The base tree with the probes gives the 0.1.3 release check's `[rts]` game lines exactly
  (M1 501 and 801-805: the same multiset of lines up to the autotest summary; only the order of same-tick lines, from the
  probe's extra handlers, and the probe's own timestamps differ). M1 53/53, 25,678 train items; Age III 5/5; linked
  12/20; aggressive first line 3/5. Any change perturbs a match from about minute 3, so five seeds separate levers only
  roughly; the probe's mechanism figures carry the attribution.

## 3. Diagnosis on 0.1.3 (base tree)

Rail programs' wait budget to 35:00 (801-805, program-minutes in "depots" or "building" with an escrow short of an
item; a program short of two items counts in both): steel 384, iron 280, copper 240, circuits 67; trunk edges held by
the planner 216 edge-minutes.

- **Copper (the issue).** 9 of the 20 capitals smelted 37-38 copper a minute (one smelter slot) until minutes 15-34:
  the second copper slot is the opening's last step, and the governor's "copper runs short" rule queued a slot only
  with the third extractor (two extractors per slot, but a slot makes 37.5 plates a minute and an extractor mines 60
  ore). Depots then waited for 10 copper with 0-29 in the capital: 801 rts-ai-1 7 minutes, 801 rts-player 8, 803
  rts-player 18 (its trunk edges held meanwhile).
- **Iron (the aggressive AI).** 802 and 805 rts-ai-1 waited 14 and 18 minutes for a depot's 40 iron with 0-55 iron in
  the capital: the escrow takes only iron above the reserve plus the floor (40 + 60 = 100), and every factory takes
  plates as they arrive while the barracks save for the line.
- **Steel.** After Age II the programs wait for steel (one steel chain, 19 a minute); in 5 of the 8 missed nations the
  steel chain stopped for 5-15 minutes (803 rts-player 16-29, 803 and 804 rts-ai-1 from 22 and 25, 801 rts-player
  23-36, 805 turtle 25-29). The status probe (later trees) shows why: 1-4 depleted iron extractors per capital by minute
  30 (`no_minable_resources`, never replaced) and smelters `disabled_by_script` for want of workers.
- **The planner's Age I circuit hold.** Every trunk edge waits in Age I while the capital has fewer than 40 circuits
  (`trunk.age1_circuits`); the aggressive AI has 0-16, so its edges wait for Age II.
- **Also seen.** Every nation's market AI sells its port's starting stock (300 steel, 100 circuits) at minutes 2-4,
  exactly the Charter's and the first line's goods (the ports lie about 800 tiles out, beyond the planner's
  port_reach); not changed here.

## 4. Levers

| Lever | Change | Files, key | Result | Shipped |
|---|---|---|---|---|
| L1 | The governor's "copper runs short" rule queues a copper hub slot with every extractor (it took two extractors per slot) | `ai/governor.lua`; `balance.nation.people.ai.copper_drills_per_slot = 1` | capitals on one copper slot past minute 15: 9 -> 5 of 20; linked 12 -> 13; first line 3/5; M1 53/53, 26,841, rts-ai-1 Age II 19:57 -> 15:50; Age III 5 -> 4/5 (805 45:04); train items 211,568 -> 191,413; 803 line-identical (the governor never fired before the opening's step there) | **yes** (1f4b525) |
| L1b | The copper bootstrap (the copper line's parts first in the build queue, its plates kept from make targets, goods and workshops) until the line has two slots, not one | `ai/build_order.lua`; `copper_boot_slots = 2` | written, not measured: L2 was the larger lever | no (`r5-ai/l1b-build_order.patch`) |
| L2 | A rail program whose escrow has been short for `balance.nation.rails.ai_escrow_patience` (2 min) in one phase (its depots, its crew's kits while no crew is out, its freight train's kits) pays on without the reserve and the floor (the rule a lost line's depot already has) until that phase is paid | `scripts/rails.lua` (AI program), `ai_escrow_patience` | with L1: linked 15/20, first line **5/5**, train items 240,843, capital-attacked minutes 43 -> 15; Age III 4/5 (805 40:38); the economic nations' Age II 2-5 min later; 801 rts-ai-1 never reached Age II (goods 0 % from 22:00, its smelters unstaffed), so 801 failed the war and peace criteria. Alone (`l2only`): M1 52/53 (age2_rts-ai-1 at 20:34, 20,325 items), so L1 goes with it | no |
| L2m | L2 with 0.1.3's minimum (40 iron, 20 copper, 10 circuits, 10 steel) | `ai_escrow_min` | 801-803: linked 5/12 (0.1.3 8/12, L2 9/12), first lines 28:37, none, 41:15: the capitals sit at 0-35 iron and 0-29 copper between factory crafts, so 40 blocks as 100 did; M1 53/53, 25,591 | no |
| L2s | L2 with a kit minimum (10 iron, 2 copper, 2 circuits, 5 steel: one walker, raider and heavy kit stay) and no patience while the paying city had a building damaged within `ai_escrow_calm` (60 s; then reserve plus floor as in 0.1.3) | `ai_escrow_min`, `ai_escrow_calm` | linked 13/20, first line **5/5**, train items 227,382, capital lows 349 / 212 (0.1.3 318 / 242), army at 35:00 886 (724), attacked 25 min; **one capital lost** (801 rts-ai-1 to rts-player at 46:00, its Age II at 32:07) and **M1 52/53**, 19,461 train items (the player's freight stopped at 40:00 behind line #6's construction train stuck "on_the_path", the #33 crew bug fixed by r5-rails in 84464c8) | no (ship criteria missed) |
| L3 | The planner's Age I circuit hold on trunk edges ends once rails.lua's own line is open (on L2 the aggressive AI opened that line at 16-23 minutes and then held its edges until Age II with 0-16 circuits) | `ai/planner.lua`, `trunk.age1_after_main` | measured on L2 for M1 (line-identical: there the line opened after Age II) and 801 (linked 3, Age III 42:18, the same 801 collapse); stopped when L2 needed its minimum | no |

The coordinator's ship criteria for L2 (2026-10-31): no capital lost, starving minutes 0, capital iron/copper-low
minutes within ~10 % of 0.1.3, army at 35:00 within ~10 %, M1 501 ≥ 53/53 and ≥ 25,000 train items; otherwise L1 only.
Rules kept on L1: no item is created for the AI (the lever only moves its own build queue), Skirmish paths unchanged
(the governor runs in Nation mode only), difficulty changes nothing here.

## 5. Results

First Age III / nations linked at 35:00 / the aggressive AI's first line, per seed:

| seed | 0.1.3 (base) | L1 (shipped) | L1 + L2 | L1 + L2s |
|---|---|---|---|---|
| 801 | 36:59 / 2 / 28:57 | 38:49 / 3 / 32:18 | 39:29 / 3 / 16:02 | 40:12 / 3 / 28:38 |
| 802 | 38:03 / 4 / 34:13 | 38:43 / 3 / 38:46 | 37:16 / 3 / 22:38 | 35:25 / 3 / 28:33 |
| 803 | 38:02 / 2 / 28:35 | 38:02 / 2 / 28:35 | 39:21 / 3 / 20:31 | 39:01 / 4 / 23:00 |
| 804 | 37:56 / 3 / 25:56 | 35:46 / 3 / 25:47 | 37:37 / 4 / 20:26 | 33:54 / 1 / 24:06 |
| 805 | 37:26 / 1 / 32:08 | 45:04 / 2 / 31:32 | 40:38 / 2 / 24:20 | 37:48 / 2 / 26:42 |

| 801-805 | 0.1.3 (base) | L1 (shipped) | L1 + L2 | L1 + L2s |
|---|---|---|---|---|
| Age III by 40:00 | 5/5 | 4/5 | 4/5 | 4/5 |
| nations linked at 35:00 | 12/20 | 13/20 | 15/20 | 13/20 |
| linked per doctrine (aggressive, economic, turtle) | 1/5, 11/14, 0/1 | 1/5, 12/14, 0/1 | 1/5, 14/14, 0/1 | 1/5, 12/14, 0/1 |
| aggressive first line < 32:00 | 3/5 | 3/5 | 5/5 | 5/5 |
| lines open at 60:00 | 62 | 61 | 63 | 62 |
| items by train | 211,568 | 191,413 | 240,843 | 227,382 |
| capital iron / copper <= 10 (minutes 10-35, 20 nations) | 318 / 242 | 347 / 188 | 339 / 189 | 349 / 212 |
| capital starving minutes | 0 | 0 | 0 | 0 |
| army units at 35:00 / 60:00 | 724 / 1041 | 891 / 1078 | 876 / 1066 | 886 / 1141 |
| army units lost by 60:00 | 1815 | 1636 | 1744 | 1789 |
| capital-attacked minutes | 43 | 42 | 15 | 25 |
| cities lost to nations (capitals) | 19 (0) | 13 (0) | 20 (0) | 21 (1) |
| M2 criteria (trade, war, peace, capture), seeds | 5 of 5 | 4 of 5 (802: no war ended) | 4 of 5 (801: no war, no peace) | 5 of 5 |
| seeds with a starving nation | 0 | 0 | 1 (801 rts-ai-1's town) | 0 |
| speed-1 minutes, max | 60.1 s | 60.2 s | 60.0 s | 60.0 s |
| Lua errors | 0 | 0 | 0 | 0 |

| M1 501 | 0.1.3 (base) | L1 (shipped) | L1 + L2 | L2 alone | L1 + L2m | L1 + L2s |
|---|---|---|---|---|---|---|
| score | 53/53 | 53/53 | 53/53 | 52/53 | 53/53 | 52/53 |
| train items (player + rts-ai-1) | 25,678 (14,196 + 11,482) | **26,841** (13,957 + 12,884) | 25,503 (14,525 + 10,978) | 20,325 (7,031 + 13,294) | 25,591 (10,106 + 15,485) | 19,461 (5,840 + 13,621) |
| rts-ai-1 Age II | 19:57 | **15:50** | 19:23 | 20:34 | 17:13 | 19:14 |
| failed checks | none | none | none | age2_rts-ai-1 | none | train_items |
| army at 35:00 / 60:00 | 58 / 85 | 36 / 119 | 55 / 79 | 59 / 89 | 42 / 81 | 60 / 87 |
| units lost, capital-attacked minutes | 293, 13 | 181, 6 | 153, 7 | 225, 10 | 100, 6 | 229, 13 |
| cities lost | 0 | 0 | 0 | 0 | 0 | 0 |
| speed-1 minutes, max | 60.0 s | 60.0 s | 60.0 s | - | - | 60.0 s |

Reading L1 against 0.1.3:
- **Copper.** The minute a capital first smelts 70 or more copper (two slots): median 14 -> 13, capitals still on one
  slot after minute 15: 9 -> 5. Capital copper minutes at 10 or less (10-35) 242 -> 188; iron 318 -> 347 (+9 %).
- **Age II earlier where it acts** (804: 16:20 -> 14:53, 17:05 -> 15:37, 20:53 -> 17:30; 801 rts-ai-1 20:08 -> 19:10;
  M1's rts-ai-1 19:57 -> 15:50, which gives the M1 Age II check 40 s -> 4:40 of margin), line-identical where the
  governor never fires before the opening's own step (803).
- **The army** at 35:00 is larger (724 -> 891), units lost fewer (1815 -> 1636), capital-attacked minutes the same.
- **The misses the release check will see:** Age III 4/5 (805: every nation there reached Age III between 45:04 and
  55:24; 0.1.3's first was 37:26) and 802's two wars not ended by 60:00 (the peace criterion). Both are game paths that
  diverge from minute 3 rather than a mechanism of the lever, and both are within one seed.

Rail-program wait budget to 35:00 (801-805, program-minutes from the probe; a program short of two items counts in
both): 0.1.3 steel 384, iron 280, copper 240, circuits 67, edges held 216; L1 + L2 steel 481, iron 209, copper 59,
circuits 54, edges held 213. With the escrow paying on, copper stops being the wait and steel becomes it.

## 6. Checks on the shipped tree (L1 = 1f4b525, frozen tree `build/r5ai-trees/l1`)

| Check | Command | Result |
|---|---|---|
| Skirmish smoke | `KEEP_TREE=<l1> SEED=9090 tools/autotest-run.sh r5ai-l1-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65, 0 errors, line-identical to the 0.1.3 release smoke (the server's last line excepted) |
| Skirmish identity | the ten scenarios of `tools/autotest-matrix.sh` with `SEED=777 KEEP_TREE=<l1>`, one at a time (session scratchpad `r5-ai/checks.sh`), then `tools/matrix-compare.sh base0111 r5ai-l1` | 0 differing lines; summaries as the 0.1.1 baseline (stress 36/38 as there); 0 Lua errors |
| M1 501, M3 801-805 | section 5 | 0 Lua errors; speed-1 minutes max 60.0 s (M1) and 60.2 s (M3, other agents' matrices running) |
| Owner save 0.1.3 | `owner-0113-now.zip` (copy), 120 s headless on the tree (`r5-ai/owner-load.sh`) | loads, 720 `[rts]` lines, the match runs on (minutes 85-86), 0 errors, nothing reset |
| Owner save 0.1.2 | `owner-0112.zip` (copy), 120 s | loads, 690 `[rts]` lines, minutes 55-56, 0 errors, nothing reset |
| Owner save 0.1.1 Age II | `owner-0111-age2.zip` (copy), 120 s | loads, 744 `[rts]` lines, 0 errors, nothing reset |
| War paths | `tools/probes/ai3_war_paths.lua`, seed 811, 1v1 hard, SPEED 10 | 6/6 (mercenaries, hire_garrison, interceptors, holding_division, bombers, artillery_train), 0 errors |
| M1 determinism (SPEED 10 pair) | not run | the lever has no random input; the lead's release check runs the pair |

No storage structure changed (one balance key read by the governor), so old saves load as before.

## 7. Open (issue text)

Proposed issue for the next wave: **"AI rail escrow: retest the patience payment (L2) on the merged tree"**

> From docs/qa/release-0-1-4-r5-ai-notes.md (r5-ai). The binding constraint of the aggressive AI's first line is not
> copper alone: its capital sits at 0-35 iron and 0-29 copper between factory crafts, and the rail escrow takes only
> plates above the reserve plus the floor (100 iron, 80 copper, 20 circuits, 50 steel), so a depot waited 14-18 minutes
> for 40 iron (802, 805) and 7-18 minutes for 10 copper (801, 803). L2 (a program short for 2 minutes in one phase pays
> on above a small minimum; patch in the 0.1.4 session scratchpad `r5-ai/l2s+l3-on-1f4b525.patch`) gave, with L1 (the
> copper slot per extractor, shipped in 0.1.4): the aggressive first line before 32:00 in 5 of 5 seeds (16:02-28:38);
> nations linked by 35:00 15 of 20 without a minimum and 13 of 20 with the calm gate (no patience while the paying city
> had a building damaged within 60 s) and a kit minimum (10 iron, 2 copper, 2 circuits, 5 steel). That shippable form
> missed two criteria: one capital lost (801 rts-ai-1 at 46:00) and M1 501's train items (19,461): the player's freight
> stopped at 40:00 behind a construction train stuck "on_the_path", the crew bug r5-rails fixed in 84464c8 (a crew
> jammed against another train now goes home after 15 s). Wanted: rerun L1 + L2s on the merged tree with 84464c8; if
> it holds, ship it, then measure L3 (the planner's Age I circuit hold on trunk edges ends once the capital's own line
> is open). Ship criteria as in 0.1.4: no capital lost, starving minutes 0, capital iron/copper-low minutes and army at
> 35:00 within ~10 % of 0.1.3, M1 501 ≥ 53/53 and ≥ 25,000 train items. Targets of #2 stay: linked by 35:00 ≥ 16 of
> 20, the aggressive AI's first line before 32:00 in ≥ 4 of 5.

Also open, with the numbers for later issues:
- **Steel after L2.** The rail programs then wait mostly for steel (481 program-minutes to 35:00): one steel chain (19
  a minute) per capital in Age I. Steel stops for 5-15 minutes in some capitals: 1-4 iron extractors per capital are
  depleted by minute 30 (`no_minable_resources`, never replaced: the governor's "runs short" rule covers stone, copper
  and coal, not iron) and smelters stand `disabled_by_script` for want of workers. Candidate: replace depleted iron
  extractors from the line's free drill spots; staff the steel chain first.
- **Capital labour deadlock.** Goods at 0 % with the workforce below the jobs stops growth for good: 801 rts-ai-1 on the
  L2 trees stood at 182 residents, 109 workers for 218 jobs, goods 0 % from 22:00 to 45:00, 11 smelters disabled, and
  never reached Age II. 0.1.3 shows the same outages for 8 minutes (801 rts-player, 803 rts-ai-1).
- **The Age II road against the rails.** With L2 the economic nations reached Age II 2-5 minutes later (the rails took
  the Age I plates first) and Age III moved by about a minute on average; a gate "no patience while the Charter is
  delivered" for the economic doctrine is the next lever to try with L2.
- **Port stock.** Every nation sells its port's starting 300 steel and 100 circuits at minutes 2-4.
- **#20 item 4** (army.step pool passes) unchanged; the rails-side items of #33 are r5-rails'.

## 8. Proposed changelog lines

```
AI (Nation):
  - AI capitals short of copper build their second copper smelter with the next copper extractor, so copper reaches
    two smelters' output earlier in Age I (the aggressive AI reached Age II about 4 minutes earlier in the 1v1 test).
```
