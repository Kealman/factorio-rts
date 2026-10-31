# Release 0.1.4, agent r5-rails: junction signals, the way home and track removal (#41), rails follow-ups (#33)

Date: 2026-10-31. Branch of `main` da0ec26 (0.1.3 + the 0.1.4 plan). Factorio 2.1.24 (Steam updated it from 2.1.23 before
these runs; the 0.1.3 acceptance ran on 2.1.23, and seed 801 plays the same on both, section 7), mac-arm64, Space Age on.
Plan: `docs/qa/release-0-1-4-plan.md` (rules of the 0.1.2 and 0.1.3 plans).

## 0. Summary

| Item | Commit | Result |
|---|---|---|
| #41 (signals at real junctions, old saves repaired, the way home, own track and signals removable) | 31b9446 | The owner's save: 48 -> 14 signals (one pair per branch of 3 real junctions), its 2 signal ghosts kept, train 76 home in 28 s; the cause was a second signal pair at one joint making the main line one-way, not pairs at every join (joins never got signals). Fixtures 19/19 (r3_rails_manual) and 17/17 EN/RU (planner GUI probe with removal), smoke 65/65, the 3 owner saves 0 errors, M1 501 line-identical to 0.1.3 |
| #33 item 6 (remove built track) | 31b9446 | with #41 item 3 |
| #33 item 3 (overlapping surveys) | 4f6b69c | no overlap of surveys (the scheduler runs them in order); the 0.1.3 detour was a junction pair on a planned ghost, fixed by #41; fixture check `surveys_apart` |
| #44 (an idle work train blocks the crews; waits without a reason) | 49604d8 | On `owner-0114-now.zip` the builder's work train 97 on Depot #1722's platform is taken as the crew 11 s after load and builds the planner loop's line #38 by 47 s (it was turned round first: only its far end was reachable); fixture 22/22 (`adopt`, `adopt_built`), smoke 65/65, M1 501 line-identical to 0.1.3 |
| #33 item 4 (busy platforms, AI crews standing still) | 84464c8 | crews jammed against a crossing train go home after 15 s (801), trains on another block no longer make a platform busy; the AI's acceptance numbers unchanged (M1 53/53 and 25,678 train items, Age III 5/5, linked 12/20, aggressive first line 3/5); fixture 20/20, smoke 65/65 |

## 1. #41: what happened on the owner's save

Fixture: a copy of `build/saves/owner-0113-now.zip` (0.1.3, minute 85). Diagnostic modules in the session scratchpad
(`r5-rails/diag76*.lua`, loaded through `r5-rails/mktree.sh` + `r5-rails/save-load.sh`), and the owner's own client log
of the session (`~/Library/Application Support/factorio/factorio-current.log`, copied to
`scratchpad/r5-rails/owner-client-1031.log`), which has every `[rts]` line of the game that made the save.

**The signals.** The 48 chain signals of rts-player were not pairs at every join of short segments: a join of two
pieces of track has two rail ends, and both the 0.1.3 `mark_junction` and `junction_signals` needed three. They were:

- 30 signals in 15 pairs every 80 tiles (`signal_spacing`) along the planner lines, mostly the 442-piece main line;
- 18 junction signals at the two switches of a passing loop the owner laid beside the main line (planner tracks #42
  from (331, -61) and #41 to (381, -11)) and at a third junction by depot #1722 (planner track #40), each a pair at the
  far end of every rail meeting there.

The clusters of 8 signals within 10 tiles were a junction's 6 plus a spacing pair that happened to stand next to it.

**Why train 76 had no path home.** At (383, -9), the joint south-east of the junction (381, -11), two pairs stood at the
same joint: the main line's spacing pair, placed first on the rail south-east of the joint (its in / out locations
(382.5, -7.5) and (384.5, -9.5)), and the junction's pair, placed later on the rail north-west of it ((383.5, -10.5) and
(381.5, -8.5)). The engine attaches one signal per side of a joint; after the second pair, one signal of the four was
attached (`get_connected_rails`: (384.5, -9.5) to the rail (384, -8), the other three to nothing). One signal alone
makes the track one-way: from (382, -10) no path led south-east any more (`request_train_path` from either end of the
rail to rails 4 and 40 tiles on: none), while the way north-west stayed open. The whole main line south-east of the loop
was one-way towards the far end. Train 76 (double-headed, built #42, stood across the switch (331, -61) with its front
on the main line and its back on the loop) had no path home from either end (`path to home: found false, steps 6` from
both ends, with and without `in_chain_signal_section`); train 69, sent at 5095 s after this junction got its signals at
5058 s, had been recalled the same way 3 minutes earlier at (202, -187). Removing the spacing pair alone, in the loaded
save, gave train 76 its path home at once (`train 76 -> home: true`).

Experiments on the save (`diag76d.lua`): a fresh pair at a free joint attaches to its rail; a second pair at a joint that
has one is refused by the vanilla build rules (`can_place_entity` with `build_check_type.manual`: false) and, created by
script, attaches to nothing; a pair at a joint that a curve covers (the 0.1.3 rule put one at every rail's far end, also
inside the switch) is refused too and attaches to nothing.

The owner's two rail-signal ghosts are unbuilt plain rail signals, one beside the main line at (337.5, -56.5).

## 2. #41: design

1. **Signals only at real junctions** (`rails.junction_signals`, `J.is_junction`): the own ground rails with an end at
   the node are grouped by the direction of that end; a node is a junction when two or more rails leave it to one side
   and at least one to the other (a switch). A join of two pieces of track (straight or through a curve) has one rail
   on each side and gets nothing; two rails to one side and none to the other neither.
2. **One pair per branch, only where it can stand** (`J.branch_joint`, `J.joint_free`): for each rail at the junction,
   the first joint along the branch (its far end, else up to `rails.JUNCTION_WALK` = 6 rails further on) where no signal
   or signal ghost of any force stands yet (all four locations of the joint: both rails' in / out, `J.joint_signals`)
   and where the vanilla build rules accept both signals (`can_place_entity`, `build_check_type.manual`) and no rail ghost
   covers either spot (a signal there kept a planned piece from being built: fixture track 2 stood at piece 2 in the
   first run). A branch that already has a signal on the way counts as signalled (the player's own pair, or the
   owner's ghost by the loop). A branch whose next rails are still ghosts gets its pair when track is built within 24
   tiles of the junction (`storage.rails.jpend`, `J.junction_retry`). The pairs are recorded
   (`storage.rails.jsig[unit number] = {e, x, y, s, rail}`), so a branch never gets a second pair.
3. **Plain player track has no signals**: planner lines and Rail tool segments get no pairs every `signal_spacing`
   tiles any more (adopt_ghosts, survey_extract for `job.manual`). The player's auto lines between depots keep their
   spacing and station pairs, now only at joints where `J.joint_free` holds; the AI's lines are unchanged.
4. **Saves from before** (`rails.fix_track_signals`, once per save: `storage.rails.signals_v` = 2, from `rails.init` on
   a version change and from the line check otherwise): the spacing pairs of planner lines and segments go
   (`line.signals`, `piece.sig`, the bill), every chain signal at the locations where 0.1.2 - 0.1.3 put junction pairs
   (the far ends of the rails at every junction mark `jpos` / `jpos2` of a player's line) goes, and the marks that are
   real junctions get their pairs again by rule 2. Plain rail signals, signals elsewhere and every signal ghost stay.
   Then every own signal attached to no rail is repaired: a detached signal does not attach again when the pair that
   took its place goes (`diag76f.lua`: after the junction pair at (383, -9) went, the spacing pair stayed half attached
   and the track one-way), so the signals of its joint are taken up and set again, those attached before first, and
   removed when they do not attach as a pair (both directions); the junctions are signalled once more after that
   (`diag76g.lua` set a detached second pair at that joint by script and ran the repair: one attached pair left, the path
   south-east open). Trains of the force without a path try again. One log line per force: `rails: signals of <force>
   (0.1.4, #41): N before, M after: ...`.
5. **The way home** (`builder_step`, player crews only; `H.way_home`, `H.no_path_reason`): a crew on its way home that
   has no path tries at once (a) the engine's own path from either end of the train (`request_train_path` with the
   train: both ends with a locomotive, the double-headed crew has two), (b) back to the rail it parked on before it
   turned into its line (`rails.manual_via` / `manual_approach`: a branch that leaves backwards is entered by a reversal,
   so the way home starts with one), when both legs have a path, (c) the nearest own depot it can reach (0.1.2). After
   `rails.HOME_NOPATH_TICKS` (30 s) still without a path it is recalled (kits, rails and coal back to its depot, as the
   120 s stuck rule did) and the log says why: `rails: construction train N has had no path home for 30 s at (x, y):
   no path to depot #D (2 of its stops on track): from its front at (..) none, from its back at (..) none; S signals
   within 40 tiles, odd ones at (..) (no partner: one-way) ...`. The 120 s stuck rule stays for the other cases.
6. **Own rails and signals in the piece selection** (#41 item 3 = #33 item 6; `scripts/pieces.lua` kind `"track"`,
   `rails.remove_track`, `rails.describe_track`, `rails.signal_partners`; `selection.lua`, `demolish.lua`): a click selects
   one own ground rail or signal (a signal with its partner on the other side of the track: `pieces.expand`), a box the
   own track and signals in it; the HUD's piece page says what it is ("Your track (track line N)", "Chain signal the
   game put at a junction", "Platform of Depot N: it goes only with the depot", ...). Delete or Backspace twice removes
   them as one batch:
   - kept, with a message: rails under a train (`LuaTrain.get_rails` of the trains within 12 tiles), depot platforms,
     pieces of auto lines between depots and the player track such a line runs along (lines are not taken apart here);
   - the signals at the joints of a removed rail go with it, and the game's pairs of a junction that is no junction any
     more (`storage.rails.jsig` by junction);
   - refund to the nearest stockpile (`buildings.deliver_items`, with the other pieces of the batch): a rail of a line
     its piece's rails, any other rail the items it is built from (`items_to_place_this`); a signal of the player its
     item; one of an auto line's spacing pairs `signal_rails` rails; a junction pair the game placed for free nothing;
   - a planner line or Rail tool segment that loses pieces is split into the runs that stand (`J.split_line`): each run a
     line of its own (open when built, else building, so robots and crews finish it and destroyed rails are repaired
     as before), nothing removed comes back; a crew of the old line goes home ("no line").
   - log line `rails: track removed by player N (<force>): R rails, S signals, refund [...]; kept ...; lines #...`.

## 3. #41: tests

| Test | Command | Result |
|---|---|---|
| Manual track fixture (`tools/probes/r3_rails_manual.lua`), with the new checks `short_signals`, `spur`, `remove_junction`, `remove_track`, `crews_home` | `SEED=501 SPEED=6 EXTRA_LUA=tools/probes/r3_rails_manual.lua STOP_ON='r3 manual summary' tools/autotest-run.sh r5-manual '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 2400` | **19/19** (0.1.3: 14/14 + the new checks). Track 1: 280 pieces built by a crew in 199 s; track 2 (a branch that leaves track 1 heading west) in 174 s (0.1.3: 185 s), its junction 6 chain signals: pairs at (270, 7) and (282, 7) on the main track (the first joints the branch's curve leaves free, walked 5 and 1 rails), and at (271, 11) on the branch once its second piece stood (`jpend`; the first run, without the rail ghost rule, put the west pair onto the ghost of piece 2 and the crew stood at it for 10 minutes); track 3 in 78 s, 6 chain signals at its junction (168, 7) (0.1.3: 58 s; the check now finds the junction from the line's mark, the survey runs along track 1 for 19 tiles first); auto lines A - C 99 % and A - B 100 % reused, A - D open after 59 s (95 % reused; 0.1.3: 221 s, 89 %); trains 1 and 2 10 and 11 loops in 20 minutes, longest stand at a signal 39 s (0.1.3: 49 s); warnings, platform_held, own_land, track_waits, cancel as in 0.1.3. New: **short_signals** ten short segments laid one after another from B's free platform end, each surveyed and handed over on its own (54 pieces in 10 planner lines, crews from B built them in 300 s): **0 signals, 0 signal ghosts** on them; **spur** a branch off segment 8: 6 chain signals at its junction (715, 23); **remove_junction** its first rail removed: 1 rail, the junction's 6 signals went, 0 left, the spur's line goes on without its first piece; **remove_track** the 16 rails of segments 4 to 6 removed, 24 rails refunded (their pieces' 24), their 3 lines gone, segments 3 and 7 still lines, a platform rail of A refused, after 40 s nothing back; **crews_home** the crew of the spur was out beyond the removed stretch: "construction train 153 has had no path home for 30 s at (735.5, 31.2): no path to depot #417 (2 of its stops on track): from its front at (732, 31) none, from its back at (751, 42) none; 0 signals within 40 tiles; recalled to depot #417" |
| Planner GUI probe, real input, EN and RU (`tools/probes/r4_rails_planner_gui.lua`, with `remove_select`, `remove_rail`, `remove_signal`, `remove_box`) | `scratchpad/r5-rails/mktree.sh mods/factorio-rts build/r5p-<l> - tools/probes/r4_rails_planner_gui.lua`; `tools/gui-drive.sh build/r5p-<l>-gui.log build/shots-r5p-<l>-window RTS_R4P_DONE &`; `RTS_LOCALE=<l> tools/gui-run.sh build/r5p-<l> 1100 RTS_R4P_DONE` | **17/17 in both**. The 0.1.3 checks as before (track 1 18 ghosts, built in 12 s; the branch junction 6 chain signals; the freight train at Station 2 after 9 s; the stop list warnings); a click on a rail of the diagonal selects it ("Straight rail / Your track (track line 2) / Delete (twice) removes it ..." on the HUD page, window capture `remove-select.png`), Backspace twice removes it (refund 1 rail, its planner line split in two: 4 -> 5 lines); a click on a junction chain signal selects it with its partner (2 boxes, "2 x Rail chain signal"), Backspace twice removes both (6 -> 4 chain signals at the junction); a box over the diagonal's last 3 pieces selects 3 rails, Backspace twice removes them (refund 3 rails). Screenshots `build/shots-r5p-en/`, `build/shots-r5p-ru/`, window captures `build/shots-r5p-<l>-window/` |
| Schedule fixture (`tools/probes/r3_rails_schedule.lua`), on the branch head 39e20e9's mod | `SPEED=8 DURATION_MIN=40 EXTRA_LUA=tools/probes/r3_rails_schedule.lua STOP_ON='r3 schedule summary' tools/autotest-run.sh r5-sched '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' 900` | **8/8**, 0.1.3's numbers (7 loops, 59,762 copper, the junction crossed 15 and 29 times, 0 s at a signal, 22 artillery loops) |
| Train builder fixture (`tools/probes/r3_rails_builder.lua`), same | `SEED=501 SPEED=4 EXTRA_LUA=tools/probes/r3_rails_builder.lua STOP_ON='r3 builder summary' tools/autotest-run.sh r5-build '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 900` | **8/8** |
| Skirmish smoke | `tools/autotest-run.sh r5-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65, 0 errors (before each commit) |

## 4. #41: the owner's saves and identity

| What | Command | Result |
|---|---|---|
| `owner-0113-now.zip` (copy; the test tree's version bumped to 0.1.4 so `on_configuration_changed` runs, as the development install will), 130 s, with `diag76e.lua` | `scratchpad/r5-rails/save-load.sh build/trees/r5fix 130 r5-own0113 <save>` | **0 errors.** `rails: signals of rts-player (0.1.4, #41): 48 before, 14 after: 30 spacing signals of player track and 18 old junction signals at 4 junction marks removed, 14 signals placed again at 3 real junctions, 0 loose signals removed; 2 signal ghosts kept (2 before)`. Junction (331, -61): pairs at (329, -63) and (338, -49) (on the loop, 3 rails along: the curve covers the nearer joints), the main track south-east counts as signalled by the owner's rail-signal ghost at (337.5, -56.5); junction (381, -11): pairs at (383, -9), (373, -19), (372, -15); junction (1086, 639) by depot #1722: 2 pairs, one branch signalled already. Every signal attached. **Train 76** goes on at once (on_the_path at 2.5 s) and is back in depot #1722 at 29.8 s: `construction train 76 back in depot #1722: 0 rails returned, kits stored` |
| `owner-0112.zip`, same | `... r5-own0112 owner-0112.zip` | **0 errors**, 743 `[rts]` lines; the 13 Rail tool segments become planner track as in 0.1.3 (456 ghosts, 1 track line); the signal repair found nothing to do (`0 before, 0 after`) |
| `owner-0111-age2.zip`, same | `... r5-own0111 owner-0111-age2.zip` | **0 errors**, 807 `[rts]` lines; "the Station and the signals unlocked" as before; no player track, no signal line |
| AI identity, M1 seed 501 (Nation 1v1 2048, 60 min) against the frozen 0.1.3 tree 61d6f05 | `KEEP_TREE=build/trees/61d6f05/mods/factorio-rts TREE_B=build/trees/r5-31b9446/mods/factorio-rts WHAT=all tools/determinism-compare.sh r5r-m1 '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 60 501` | **line-identical**: 68,801 `[rts]` lines on each side, 0 differing (31b9446's mod; the stagger listing does not differ either: no new periodic handler). Headless runs have no players, so no force is human: junction signals, the way home and the signal repair never run for the AI |
| Skirmish identity matrix (10 runs, seed 777) against base0111, #41 | the lead's run on `main` 5d71b92 (= da0ec26 + 31b9446), 2.1.24 | **0 differing lines** in all 10 scenarios; smoke 65/65; the three owner saves 0 errors (48 -> 14 signals, train 76 back in depot #1722) |
| Skirmish identity matrix (10 runs, seed 777) against base0111, 84464c8 (#41 + #33 items 3 and 4), 2.1.24 | `scratchpad/r5-rails/matrix.sh r5i4 build/trees/r5-84464c8/mods/factorio-rts` (= `KEEP_TREE=<frozen tree> SEED=777 JOBS=1 tools/autotest-matrix.sh r5i4; tools/matrix-compare.sh base0111 r5i4`) | **0 differing lines** in all 10 scenarios (1v3 stress 36/38 as base0111, the rest all passed; 0 Lua errors) |

## 5. #33 item 6: remove built track

Done with #41 item 3 (section 2, point 6; tests in section 3: fixture checks `remove_junction`, `remove_track`,
`crews_home`, GUI probe checks `remove_select`, `remove_rail`, `remove_signal`, `remove_box`). The 0.1.3 open item "a
'remove this track' action for built rails" is closed; lines between depots stay out of it (section 9).

## 6. #33 item 3: overlapping surveys

**What it was.** Surveys do not run at the same time: in a Nation match each survey is a scheduler job, and a force's
jobs run in queue order (`sched.lua`: the first job takes the whole budget until it is done, the survey step never
yields), so a second line searches its route after the first one's ghosts stand, and the ghost check keeps its pieces
off them. In the fixture (A - C, A - B and A - D surveyed in the same tick) the surveys finished one after another
(3.5 s, 4.3 s, 9.3 s). The overlap of 0.1.2 and 0.1.3 was something else: in the 0.1.3 fixture run
(`r4-manual-server.log` of that worktree) A - D's piece 117 (curved-rail-b at (257, 9)) "will not revive" because of a
`rail-chain-signal` at (255.5, 8.5), a junction pair that A - C's crew had put up at the far end of a rail when A - C's
junction piece stood, on top of A - D's planned ghost; A - D was blocked for 121 s and took a detour (open after 221 s).

**Fix.** That is #41's placement rule: a junction pair never goes where a rail ghost covers a signal's spot
(`J.signal_fits`). A survey-side wait (a player's survey waiting for an overlapping one ahead of it) was written and
dropped: it never triggered, since the scheduler already orders the surveys.

**Test** (fixture check `surveys_apart`, added): PASS, "A-C, A-B, A-D surveyed together: 15 new pieces, 0 laid twice, 0 blocked pieces or detours"; A - D opens after 59 s with 95 % of its pieces reused (0.1.3: blocked at piece 117, a detour, open after 221 s, 89 %).

## 7. #33 item 4: busy platforms and the AI crews that stood still

**Where.** On the 0.1.3 acceptance runs (`build/release-check/2026-10-28_0145`, logs `build/rc-2026-10-28-0145-m3-80*`)
only seed 801 has crews standing "on_the_path" at speed 0: construction train 153 of rts-ai-1 (line #10, minute 39,
at its rebuilt depot #9646) and train 328 of rts-ai-2 (line #18, minute 56), each 120 s until the stuck rule sent it
home; 804 had none in that run (r4-ai saw 9 events on its own trees), and 804's line #10 logged "waits for a
construction train: busy" 24 times. The game is deterministic: a 60-minute `--benchmark` of seed 801
(`tools/perf-bench.sh match`, about 3 minutes of wall clock) on the #41 tree with a read-only module
(`scratchpad/r5-rails/r5_crew_diag.lua`: a crew at speed 0 "on the path" for 20 s is dumped with its fuel, path, the
entities around its carriages and the other trains near it; a line that waits "busy" logs what is in its depots'
platform areas and blocks) reproduces the acceptance run exactly (11 lines open, 2 crews stuck "on_the_path", 3 busy
waits, 16 freight trains run) and both crews at the same places.

**Cause.** Crew 153 stood with fuel (20 + 16 coal, burning), a path (23 rails, 4 of 64.7 tiles travelled) and no
signal; freight train 113 of rts-ai-1 (to its pickup, on the path, speed 0) stood across the curve at the platform's
end (x = 683), its stock touching the crew's back locomotive (spark explosions at both), and
`is_rail_in_same_rail_block_as` put both trains in one rail block: another line crosses the platform's end inside the
platform's block (the station-entry signals of an AI line stand one piece out), so a train created by script there is
not held by any signal, and when the crossing train came through, the two met and stood nose to nose for good. Crew 328
stood the same way 26 tiles out, with a freight train across its track. Separately, `platform_free` counted all rolling
stock in a platform's area (the platform track and 4 tiles to each side), on the platform or not: in the same run
rts-ai-2's line #12 waited "busy" for minutes while freight train 167 stood in depot #11025's area, not on its platform,
at the station of the depot beside it (the "flipping" r4-ai saw in 803 and 805). The diagnostic's block dump of a later
run showed such a train (197, beside depot #11163) in the waiting platform's own rail block: the platforms of the two
depots are joined end to end by unsignalled track.

**Change** (AI and players alike):
- `platform_free` (`J.platform_busy`): rolling stock in the platform's area makes it busy only when its train is in the
  platform's rail block (any of its rails); a platform with a rail gone counts all of it, as before. Never busier than
  0.1.3.
- `crew_stuck` (`J.jammed`, `rails.CREW_JAM_TICKS` = 15 s): a crew that stands "on the path" at speed 0 with another
  standing train's stock within 5 tiles of a carriage goes home after 15 s instead of 120 s (`rails: construction train
  N stands against another train at (x, y)`), and on its way home the same rule recalls it; the crossing train goes on.
- Tried and dropped: busy while any train is in the platform's block (801: crews waited 17 times, lines open 9 of 11 at
  60:00, because AI platforms share blocks with long stretches of other lines), and busy while a moving train is within
  12 tiles in that block (it caught crew 153 but not a crew that a freight train hit right after its deploy: 801 still
  had a jam). Deploying a crew where another line crosses the platform's end stays possible; the jam rule ends it fast.
- The player's extra rule (a train with a path ending on the platform makes it busy) stays: on plain player track, a
  train spawned into the stretch another train has reserved would meet it nose to nose. Deploying "between arrivals" or
  a deploy siding (the issue's suggestions) needs that stretch signalled, which plain player track deliberately is not
  (#41); a player who wants deploys while trains come in lays a passing loop or a second track at the depot.

**Measured** (`scratchpad/r5-rails/accept-bench.sh`: the acceptance probes of release-check's m1 and m3 stages as
`--benchmark` matches on the frozen 84464c8 tree, one at a time; `scratchpad/r5-rails/railstats.sh` counts the rail lines
of the logs; 0.1.3 = the acceptance logs `build/rc-2026-10-28-0145-*`):

| Seed | Lines open (0.1.3 / 84464c8) | Crews stuck, of them "on_the_path" | Busy waits | Freight trains run |
|---|---|---|---|---|
| 801 | 11 / 11 | 2, 2 / 1, 1: crew 153 "stands against another train", home after **15 s** (was 120 s); crew 328's jam no longer happens | 3 / 3 | 16 / 15 |
| 802 | 10 / 10 | 7, 0 / 7, 0 (line #15's crews at a signal, the line never opens, unchanged: section 9) | 0 / 0 | 15 / 15 |
| 803 | 10 / 10 | 1, 1 / 1, 1 (crew 207 recalled by the stuck rule after its detour wait, unchanged: section 9) | 1 / 0 | 11 / 11 |
| 804 | 10 / 10 | 0 / 0 | 24 / 24 | 11 / 11 |
| 805 | 12 / 12 | 1, 0 / 1, 0 | 18 / 18 | 15 / 15 |

The crews move on 801 (the jam ends after 15 s and line #10 opens as before) and 804 has none standing in either run. 804's
24 and 805's 18 busy waits stay: there the rolling stock in the platform's area stands in the platform's own rail block
(depot platforms joined end to end by unsignalled track), where a train spawned by script would run into it; only a
train on another block no longer counts (803: 1 -> 0).

## 8. The AI's numbers (plan rule 3)

#41 and item 3 do not touch the AI (M1 seed 501 line-identical to 0.1.3, section 4). Item 4 changes the AI's crews on
purpose; on 84464c8 (`build/release-check/r5-i4/REPORT.md`, the same tables as the 0.1.3 acceptance
`build/release-check/2026-10-28_0145/REPORT.md`; benchmark runs on 2.1.24, which play the 0.1.3 tree's seed 801 exactly as
the 2.1.23 acceptance did):

| Number | 0.1.3 acceptance | 84464c8 |
|---|---|---|
| M1 501 checks, train items | 53/53, 25,678 | **53/53, 25,678** |
| Age III by 40:00 | 5 of 5 (36:59, 38:03, 38:02, 37:56, 37:26) | **5 of 5** (the same minutes) |
| Nations with 3 cities linked by 35:00 | 12 of 20 (2, 4, 2, 3, 1) | **12 of 20** (2, 4, 2, 3, 1) |
| Aggressive AI's first line before 32:00 | 3 of 5 (28:57, 34:13, 28:35, 25:56, 32:08) | **3 of 5** (the same) |
| Trade / war / peace / capture, starving, capital lost | P/P/P/P in 5 seeds, 0 starving | **the same** |

Every number is kept; 0 Lua errors. (The report's AI autotest column reads "-" for benchmark logs. Its informational
fort-belt counts are 2, 5, 0, 13, 34 against 11, 6, 0, 15, 35: 801's war goes differently after the shortened jam; a
benchmark and a server run of one tree were not compared for 802 to 805.)

## 8a. #44: an idle work train and a planner loop that never got a crew

**What the save shows** (`build/saves/owner-0114-now.zip`, the 0.1.4 development build, loaded on the branch with a
read-only module `scratchpad/r5-rails/diag44.lua`): train 97 (the builder's Construction preset: two locomotives and a
construction wagon) stood in manual mode on Depot #1722's platform; its record's kind was "cargo" (the builder's
`dominant` kind ignores construction wagons), so the one-crew guard of `dispatch_manual` did not see it, but it kept the
platform busy (`deploy_check`: busy), the panel's "the platform is occupied ...". The planner loop near the capital was
lines #38 (18 pieces, 6 to build) and #39 (26, 22 to build), both waiting "no-access": #38's first piece met #37, a
one-piece track that only #38 itself would connect to the network, and its far end met the main line's last piece
(#36) at (161, -211); `planner_orient` took the built rail at the start and never turned it round, #39 hangs behind
#38. The issue's reading (the guard returns for the idle train) does not hold for this save, the effect is the same.

**Change** (scripts/rails.lua `dispatch_manual`, `J.idle_crew`, `J.turn_for_access`, `J.track_wait`,
`rails.track_lines_of`; scripts/railgui.lua; locale EN/RU):
- an idle work train of the force on the platform of the depot a crew would come from (two locomotives and a
  construction wagon, manual mode, no stop list, standing still) is taken as the crew instead of deploying one: it gets
  its rails and coal from the network and goes; at the end it goes home into kits like every crew (log "the work train
  N standing on depot #D's platform is taken as its crew");
- a planner line that no depot reaches at its start while one reaches the built rail at its far end is turned round;
- the one-crew rule stays (a crew is a construction train on a job); its wait names the crew's line; every wait of a
  track line is logged once per change ("track segment #N (<force>) waits: <reason> [detail]");
- the depot panel lists the force's track still to be built under its lines, up to 4 rows: "Your track N: M of K pieces
  to build, waiting: no built track from one of your depots leads to it yet / it waits for the planned track before it /
  a construction train is out on track line N / you have no depot on this map / no construction train kits ... / fewer
  than 40 rails ..." or ", a construction train is on it";
- the builder's preset drop-down tooltip: crews leave the nearest depot by themselves, an assembled work train is taken.
- Not done: a second idle work train for a line on separate track while one crew is out (issue item 2's second half);
  one crew at a time stays.

**Tests.** `owner-0114-now.zip` (a copy, 0.1.4 test tree, 100 s): `planner track #38 of rts-player turned round: no
depot reaches its start, one reaches its far end at (161.0, -211.0)` at 10.2 s, `the work train 97 standing on depot
#1722's platform is taken as its crew` and `construction train 97 from depot #1722, 15 rails loaded of 15 needed` at
11.2 s, `track segment #39 waits: crew-out 38`, `track segment #38 of rts-player built: 18 pieces (12 robots, 15 crews)`
at 47.2 s; 0 errors. Fixture `r3_rails_manual.lua` **22/22** with `adopt` (a Construction train assembled at A, idle on
its platform, is the crew of a segment laid from A's free west end 1 s after it was laid) and `adopt_built` (built 15 s
after the crew left); smoke 65/65; M1 501 against 61d6f05: 68,801 lines each, 0 differing (the working tree with #44,
`KEEP_TREE=build/trees/61d6f05/... TREE_B=build/trees/r5-44/mods/factorio-rts WHAT=all tools/determinism-compare.sh
r5r44-m1 ... 60 501`). The Skirmish matrix was not run again for #44: its code runs only for a player's track lines and
in the depot panel (Nation mode); 84464c8's matrix is 0-diff.

## 9. Open items

- **Lines between depots** are not removed with Delete: their own pieces, depot platforms and the player track such a
  line runs along stay (a message says so). Taking an auto line apart (its record, its freight trains' stops, its
  repair crews) is a feature of its own.
- **The HUD's Demolish tooltip** for a selection with track still says "Half of the recipe cost comes back" (hud.lua,
  r5-hud's file): rails come back whole. Proposed: a `rts.track-demolish-tooltip` when the selection holds track.
- **Deploys while trains come in** (#33 item 4, player depots): a platform stays busy while a train of its block stands
  in its area or a train has a path ending on it; plain player track has no signals, so the stretch to the next junction
  is one block. A deploy siding per depot, or deploying "between arrivals" safely, needs a signalled stretch; not done.
- **Crossings at platform ends** (AI): a line that crosses another depot's platform end shares its rail block, so a crew
  deployed there can still run into a crossing train; the jam rule (15 s) ends it, crossing signals would prevent it.
- **Junction pairs further out**: where a curve covers the joints next to a switch, a branch's pair stands up to 6 rails
  along it (the owner's loop: (338, -49), 12 tiles from the switch); a branch that only gets signals later (its next
  rails still ghosts) gets them when track is built within 24 tiles of the junction. A junction whose branch rail is
  never followed by a joint where signals fit keeps that branch unsignalled (logged "without a joint for signals yet").
- **A player's own single signals** stay as they are: one rail or chain signal makes the track one-way (the owner's two
  unbuilt rail-signal ghosts would, once built). The help card says so; nothing enforces pairs.
- **The 0.1.3 diagnosis hypothesis** ("pairs at every join of short planner segments") did not hold on the save: joins
  never got signals. The fixture check "ten short segments in a row produce 0 signals" guards it anyway.
- The detour bookkeeping of the AI's crews: a crew that waited at a blocked piece and is then sent home for the detour
  survey is recalled at once by the stuck rule, its timer having run while it waited (0.1.3 803, crew 207). Harmless
  (the detour starts at once), left as it is.
- 802's line #15 (rts-player, played by the AI in the 4-nation runs): every crew from depot #11288 stops at a signal at
  (597, -167) a few tiles out of its platform and is sent home after 120 s ("stuck ... (wait_signal)", seven or eight
  crews, 0.1.3 and 84464c8 alike); pieces 16 to 83 are never laid and the line never opens. A block beyond that signal
  stays occupied; not looked into (it is the same in 0.1.3, and a fix changes the AI).
- Depot platforms joined end to end by unsignalled track (an AI capital's depots side by side) share a rail block, so
  one's freight train keeps the other busy (804: 24, 805: 18 busy waits). A signal pair between adjacent platforms would
  separate them; not done (it changes the AI's lines).

## 10. Proposed changelog lines

```
Features:
  - Railways: your own track and signals can be removed: click a rail or a signal (or drag a box over your track) and
    press Delete twice. The rails go back to the nearest stockpile; a signal goes with its partner on the other side of
    the track; planned track that loses a piece is split into the parts that stand. Rails under a train, depot
    platforms and the track of lines between depots stay. (#41, #33)

Changes:
  - Railways: the game puts chain signals only at real junctions of your track, one pair on each branch where signals
    can stand; plain track has no signals any more (one train per stretch between junctions and stops; lay a passing
    loop or your own chain signal pairs for more). A save from 0.1.3 or older loses the old signals of its track and
    gets its junction pairs placed again when it loads; your own signals and signal ghosts stay. (#41)
  - Railways: a construction train that finds no way home goes back past the junction it came in through, or to
    another depot it can reach; after 30 seconds without a path it is recalled and the log says why. (#41)
  - Railways: a work train you assemble with the builder (Construction) and leave on a depot's platform is taken as
    the construction crew for your track; the depot panel lists your track still to be built and what each piece
    waits for. (#44)

Bugfixes:
  - Railways: a second signal pair placed at a joint that had one made the track one-way, and construction trains
    stood with no path home (the owner's save: the main line south-east of a passing loop). (#41)
  - Railways: track you laid onto a short piece of track that only it would connect was never built (no crew could
    reach its start); it is now built from its other end. (#44)
  - Railways: a junction's signals no longer stand on track still to be built, which kept a piece of another line from
    being built and sent that line round a detour. (#33)
  - Railways: a construction train that ran into another train (a line crossing next to its platform) stood for two
    minutes; it now goes home after 15 seconds and the other train goes on. A train on a track beside a platform no
    longer keeps that depot busy. (#33)
```
