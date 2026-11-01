# Release 0.1.4, agent r6-rails: depot demolition (#45), rails leftovers (#33), a second work train (#44 item 2)

Date: 2026-11-01. Branch of `main` 3abff7b (0.1.4 development build 2 + the plan). Factorio 2.1.24, mac-arm64, Space
Age on. Plan: `docs/qa/release-0-1-4-plan.md` section 5 (rules of the 0.1.2 and 0.1.3 plans). The A side of every
comparison is the frozen 0.1.4 development tree `build/trees/115ac7c/mods/factorio-rts` of the main checkout. Helper
scripts: the session scratchpad's `r6-rails/` (`run.sh`, `bench.sh`, `accept-bench.sh`, `m3stats.py`, `gui.sh`,
`save-load.sh`, `saves.sh`, the diagnostic modules `diag45.lua`, `mkorphan.lua`, `r6_signal_diag.lua`,
`r6_block_diag.lua`).

## 0. Summary

| Item | Commit | Result |
|---|---|---|
| #45 a demolished depot takes its platform; old saves | 33d9846, dd408c1 (GUI probe) | platform rails, stops and the signals at their joints go, half of the rails come back with the refund; a train on the platform (at a station's stop) refuses with a message naming it; the depot's lines become plain removable track; a player's depot destroyed in a war leaves plain track; `rails.fix_orphans` repairs a save once. Fixture 29/29 (7 new checks; 32/32 with #44 item 2), GUI probe EN and RU 20/20 (3 new checks), smoke 65/65, the 4 owner saves 0 errors, M1 501 line-identical, Skirmish matrix 0 lines |
| #33 lines between depots removable with Delete | 33d9846 | Delete on a piece of a line between depots, or on player track it runs along, removes it and dissolves every such line (one message per line); fixture `line_delete` |
| #33 HUD Demolish tooltip for track | 00796dd | `rts.track-demolish-tooltip` when the piece selection holds an own rail or signal (`hud.lua` `update_pieces`, two lines; r6-hud informed and keeps off them) |
| #33 M3 802: rts-player's line #15 never opens | c671b64, cb9a7da | cause: a freight train of a given-up line stood `no_path` for good on a platform the new line crosses (one unsignalled block); such a train is scrapped after `AI_FREIGHT_STUCK`. 802: line #15 opens, lines open 14 -> 16, crews stuck 7 -> 1, items by train +7.6 %; 801, 803, 804 unchanged, 805 -0.2 %; acceptance criteria unchanged |
| #33 adjacent AI platforms in one block (804, 805) | - | investigated, not changed: the shared blocks come from lines crossing near the capitals, not from platforms side by side; proposal in section 6 |
| #44 item 2 a second idle work train on separate track | 4f0e775 | while a crew is out, an idle work train on a depot's platform goes as a second crew when its way and its track share no rail with the crews out (`J.apart`), else the track waits "crew-out-shared"; fixture 32/32 (`second_crew`, `second_shared`, `second_built`) |
| #40 depot panel margin (r6-hud's hunk in `railgui.lua`) | 962b9e3 | `- 2 * MARGIN` above the build menu |

## 1. #45: design

The owner (0.1.4 development build): "the rails a rail depot lays automatically cannot be removed; that is right while
the depot stands, but after demolishing the depot it must be possible to remove them too".

1. **Refusal while a train stands there** (`buildings.on_demolish_refuse`, new; `rails.lua` `J.trains_on_platform`): a
   depot with a train whose rails include a platform rail, or a station or depot with a train stopped at one of its
   stops, is not demolished. The press says why: "Depot 2 cannot be demolished: train 97 stands on its platform. Move it
   off first." ("... stands at its stop. Send it on first." for a station; RU "Депо 2: снести нельзя, на платформе стоит
   поезд 97. Сначала уведите его."). Unlike `on_demolish_check` (the Command Center, the capital), this hook does not
   grey the Demolish buttons: the train may leave a second later. `buildings.demolish` checks it too.
2. **The platform goes with the depot** (`buildings.on_demolish_extra`, new; `J.take_up_platform`), called once the
   demolish is allowed and before the depot leaves the registry:
   - the depot's lines between depots are dissolved first (`J.dissolve_depot_lines`, below);
   - the platform's index entries go (`J.unindex_platform`), so its rails are plain track for `rails.remove_track`,
     which then takes them up with the signals at their joints and the game's pairs of a junction that is no junction
     any more (log quiet: one line for the depot instead);
   - the ghosts a destroyed platform rail left for the robots go;
   - refund: half of the platform rails (10 of a 40-tile platform, 20 of an 80-tile one), with the depot's own refund
     (the alert, the "demolish: done ... refund [10 rail, 20 iron-plate, 5 copper-plate, 5 steel-plate]" line, the same
     delivery cascade); a signal there comes back as its own item. The platform came free with the depot; whole rails
     would make a build-and-demolish loop a rail mint (an 80-tile platform: 40 rails for a depot whose net cost after its
     refund is 20 iron, 5 steel and 5 copper). The issue's "refund as for the depot's own cost" reads that way; the lead
     agreed.
   - the stops go in `on_removed`, as before; log `rails: depot #N of F demolished: platform of 20 rails taken up (0 left
     standing under a train), 10 rails back, S signals, G rail ghosts removed; lines #a, #b dissolved`.
   A station has no rails of its own: its stops go (log `rails: station #N of F demolished: ...`).
3. **Dissolving a line between depots** (`J.dissolve_line`): its survey jobs (also a detour's) are cancelled, the ghosts
   of its unbuilt pieces and supports go, its built pieces lose their index entries (plain own track: Delete removes
   them, no crew repairs them, a new survey of the player reuses them at `REUSE_COST`), its signals stay as the player's
   own (Delete returns their item), a crew of it goes home ("no line"), and its depots' line slots free (a human depot's
   next line in `depot.lines` becomes its `depot.line`). Log `rails: line #N of F (depot #a - depot #b, open) dissolved
   (why): B built pieces stay as plain track, G ghosts removed, S signals stay`.
4. **A player's depot destroyed otherwise** (`on_removed` without the demolish mark, `rails.human(force)`): its platform
   stays on the ground as plain track and its lines are dissolved (`J.free_platform`). Before, the platform stayed
   protected for good and the lines stayed "lost" (nothing rebinds a player's lost line; only a recaptured depot does,
   through `on_force_changed`, which this does not touch). **The AI's path after a lost depot is unchanged**: its
   platform keeps its index for the depot the program rebuilds on the old site, its line goes "lost" and is rebound;
   the log line `rails: depot #N of F removed (platform rails stay)` is kept word for word.
5. **Saves from before** (`rails.fix_orphans`, once per save: `storage.rails.orphans_v` = 1, from `rails.init` and from
   the line check, as `fix_track_signals`): index entries of platforms whose depot is gone become plain track when the
   rail standing there (or its ghost) belongs to a player's force or nothing stands there any more; the platforms of AI
   forces stay. A player's lines between depots that lost a depot (state "lost" with a depot gone, not a captured one)
   are dissolved. Log, only when something was found: `rails: orphan platforms of F (0.1.4, #45): R rails of D gone
   depots (#...) are plain track now, lines #... dissolved`.
6. **The HUD page** of a platform rail: "Platform of Depot 1: it goes when the depot is demolished." / "Delete leaves
   it: demolish the depot and the platform goes with it (half of its rails come back)."; of a line's rail: "Track of the
   line between Depot 1 and Depot 2." / "Delete (twice) removes it: the line becomes plain track that no crew repairs any
   more; N rail(s) go back to the nearest stockpile."

## 2. #33: lines between depots removable with Delete

`rails.remove_track`: a rail of an auto line, or player track an auto line runs along (`job.reuse`), is removed like any
other own rail (its piece's rails back whole) and **every** line between depots on it is dissolved (`J.reused_by` now
lists all lines per piece; before, the last one by id was the only owner). The rest of such a line stays as plain track.
`res.dissolved` gives the message per line: "The line between Depot 1 and Depot 2 is plain track now: no crew repairs
it, Delete removes the rest." Kept: rails under a train, depot platforms ("N rail(s) stay: a depot's platform goes when
its depot is demolished, track with bridges stays"), and the pieces of a 0.1.2 Rail tool segment with bridges (its
supports would be lost by the split, as before). The planner line or Rail tool segment a removed rail belongs to (by the
index) is split as in 0.1.4 wave 1. The refund of a removed rail now reads its piece through the index's own line (an
auto line's piece number was used with a planner line's pieces before when the rail was reused track; no wrong count was
seen, it was latent).

## 3. Tests of #45 and the line removal

| Test | Command | Result |
|---|---|---|
| Manual track fixture `tools/probes/r3_rails_manual.lua` | `scratchpad/r6-rails/run.sh manual r6-man2` (= `SEED=501 SPEED=6 EXTRA_LUA=tools/probes/r3_rails_manual.lua STOP_ON='r3 manual summary' tools/autotest-run.sh r6-man2 '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 3000`) | **29/29**: the 22 checks of wave 1 as before (seg1 199 s, seg2 174 s, A - D open after 59 s, loops 10 / 11, longest stand 39 s, adopt 1 s, adopt_built 15 s), and new: **demolish_refused** depot G with freight train 176 on its platform: `buildings.demolish` false ("train-on-platform"), message `rts.demolish-blocked-train` naming train 176; **demolish_depot** the train disbanded, G demolished: 20 platform rails, 0 left, 2 stops, 0 left, refund `{rail = 10, iron-plate = 20, steel-plate = 5, copper-plate = 5}`; **depot_line** D demolished: line A - D gone, A's lines 3 -> 2, its 11 own built pieces plain track, a box near D (grown over A - D's pieces only: track 2, which A - C runs along, passes close by) removed 5 rails and 5 signals, 0 left, nothing kept; **station_demolish** Station 2085: 2 stops gone, the 2 rails under them stand; **orphan_platform** depot H's record removed the 0.1.3 way (stops gone, platform indexed): `rails.fix_orphans` freed 22 entries (H's 20 and 2 stale ones of a gone AI depot with no rail left), rail owner "platform" -> "track", Delete removed the 20 rails (refund 20 rails, whole: plain track); **depot_lost** C destroyed (`entity.die`): line A - C dissolved, its platform's 20 rails stand as plain track; **line_delete** a rail of track 1 at (519, 7) that line A - B runs along: 1 rail removed (refund 1), A - B dissolved, track 1 279 of 280 pieces stand |
| Planner GUI probe, real input, EN and RU (`tools/probes/r4_rails_planner_gui.lua`) | `scratchpad/r6-rails/gui.sh en|ru build/trees/r6-45/mods/factorio-rts 600` (mktree + `tools/gui-drive.sh` + `RTS_LOCALE=<l> tools/gui-run.sh`) | **20/20 in both**: the 17 checks of wave 1, and **platform_page** a click on a platform rail selects it, page line `rts.track-rail-platform` (window capture `platform-select.png`); **demolish_refused** every train stopped and disbanded, a freight train on the platform, a click on the depot and Backspace twice: the depot stands, the flying text "Depot 1 cannot be demolished: train 49 stands on its platform. Move it off first." (RU "Депо 1: снести нельзя, на платформе стоит поезд 49. Сначала уведите его.", `demolish-refused.png`); **demolish_depot** the train disbanded, Backspace twice: depot, 20 platform rails and 2 stops gone, track 1 (18 pieces from the platform end) stands, refund 10 rails with the depot's. Screenshots `build/shots-r6p-<l>/`, window captures `build/shots-r6p-<l>-window/` in the worktree. (Two reruns failed early because `tools/gui-drive.sh` replayed the previous run's log before the new client wrote its own; `gui.sh` deletes the old log first.) |
| Skirmish smoke | `run.sh smoke r6-smoke45 build/trees/r6-45/mods/factorio-rts` | 65/65, 0 errors |
| M1 seed 501 (Nation 1v1 2048, 60 min) against 115ac7c | `run.sh m1 r6-m1-45 build/trees/r6-45/mods/factorio-rts` (`tools/determinism-compare.sh`, `WHAT=all`) | **line-identical**: 68,801 `[rts]` lines each, 0 differing; no `depot #... removed` line (no AI depot is lost in M1 501) |

## 4. #45: the owner's saves

| Save (a copy) | Result on the #45 tree (`scratchpad/r6-rails/saves.sh build/trees/r6-45/mods 100 r6s45`) |
|---|---|
| `owner-0114-now.zip` | 0 errors, 482 `[rts]` lines in 100 s; no orphan platform (depot #1722 live, Station #1835 live); #44 as in wave 1 (planner track #38 turned round, work train 97 taken as its crew) |
| `owner-0113-now.zip` | 0 errors, 602 lines; the #41 signal repair as in wave 1 (48 -> 14); no orphan platform |
| `owner-0112.zip` | 0 errors, 573 lines; no orphan platform |
| `owner-0111-age2.zip` | 0 errors, 637 lines; no orphan platform (3 live depots, line #1 open) |
| `r6-orphan-0111.zip` (made for this test: `owner-0111-age2.zip` loaded on 115ac7c with `scratchpad/r6-rails/mkorphan.lua`, depots #3170 and #2124 destroyed with `entity.die`, saved; in the worktree's `build/saves-r6/`) | 0 errors; `rails: line #1 of rts-player (depot #2153 - depot #2124, lost) dissolved (a depot of it is gone, a save from before 0.1.4): 449 built pieces stay as plain track, 0 ghosts removed, 34 signals stay` and `rails: orphan platforms of rts-player (0.1.4, #45): 40 rails of 2 gone depots (#2124, #3170) are plain track now, lines #1 dissolved` |

None of the four owner saves has an orphan platform: the owner had not demolished or lost a depot in them.

## 5. #33: M3 seed 802, rts-player's line #15

**What happens** (802 on 115ac7c, `--benchmark` with the read-only `scratchpad/r6-rails/r6_signal_diag.lua`): at minute
~44 rts-player's far depot #4595 of its line #1 (#4249 -> #4595) is destroyed (`line #1 of rts-player lost: depot
#4595 is gone`), and 2 s later its program loses its far city #3195 to rts-ai-1 (`AI rts-player lost #3195 of its rail
program: it plans a new line`: the program goes to `R.ai_lost`). Freight train 62 of line #1 had just left depot #4249
for the pickup; it stands `no_path` on #4249's platform (track x = 635) for the rest of the match, with its pickup and
drop-off still set, so neither the program's own scrap rule (`A.line` only) nor the lost-line scrap (`not (pickup and
dropoff)`) ever sees it. The new program's line #15 (#11288 -> #11315) leaves #11288's platform eastward and crosses
#4249's platform track at about (635, -149) in one unsignalled block (its station-entry pair stands one piece out,
before the crossing). Every crew of #15 waits at that pair (613.5, -165.5) "closed": the block beyond holds train 62.
The first crew laid pieces 1-15 from the platform, the next seven stood 120 s each and went home; #15 never opened.

**Change** (c671b64, `train_step`, `J.program_line`): an AI freight train whose pickup or drop-off depot is gone and
whose line no live program holds (`R.ai[force].line`, `R.ai_more[force][i].line`) is scrapped after `AI_FREIGHT_STUCK`
(3 minutes) without a path (`rails.disband_train`: half its kits, its cargo and coal back). A program that still holds
the line (it waits to rebuild the depot on its old site, then routes the train again) is left alone: the M1 seed-501
recovery of `r2e_depot_loss.lua` is that case. cb9a7da: the scrap falls back to the force's nearest depot (after the
depot the train stands at and its home); 802 had rts-ai-1's train 240 of line #6 stranded away from any platform with
its home gone ("no-depot" logged every 3 minutes); a failed try is logged once.

**Measured** (`scratchpad/r6-rails/accept-bench.sh`: the m3 stage of `tools/release-check.sh` as `--benchmark` runs with
`m3_acceptance.lua`, report `build/release-check/r6a-115/REPORT.md` and `r6b-c671/REPORT.md` in the worktree;
`m3stats.py` for the rail counts):

| Seed | Items by train (4 nations) 115ac7c / c671b64 | Lines open | Crews stuck | Busy waits | Freight trains | Stranded trains scrapped |
|---|---|---|---|---|---|---|
| 801 | 56,284 / 56,284 | 16 / 16 | 1 / 1 | 3 / 3 | 15 / 15 | 0 / 0 |
| 802 | 34,683 / **37,311** | 14 / **16** | 7 / **1** | 0 / 0 | 15 / 16 | 0 / 1 (train 62; train 240 "no-depot", fixed by cb9a7da) |
| 803 | 40,680 / 40,680 | 14 / 14 | 1 / 1 | 0 / 0 | 11 / 11 | 0 / 0 |
| 804 | 40,600 / 40,600 | 13 / 13 | 0 / 0 | 24 / 24 | 11 / 11 | 0 / 0 |
| 805 | 41,100 / 41,024 | 16 / 16 | 1 / 1 | 18 / 18 | 15 / 15 | 0 / 1 |
| all | 213,347 / 215,899 (+1.2 %) | 73 / 75 | 10 / 4 | 45 / 45 | 67 / 68 | 0 / 2 |

The acceptance criteria are the same on both sides and equal the 0.1.3 acceptance: Age III by 40:00 5 of 5 (36:59,
38:03, 38:02, 37:56, 37:26), nations with 3 cities linked by 35:00 12 of 20 (2, 4, 2, 3, 1), aggressive AI's first
line before 32:00 3 of 5, trade / war / peace / capture P/P/P/P in 5 seeds, 0 starving, 0 Lua errors. In 802 the
fixed line #15 opens at minute 48 (after 35:00, so "linked by 35:00" does not move). r6-ai has both hashes.

## 6. #33: adjacent AI depot platforms in one rail block (804, 805): investigated, not changed

`scratchpad/r6-rails/r6_block_diag.lua` (read-only: every minute, each pair of one force's depots whose platform rails
lie in one rail block, with the rails of that block around them and the first pieces of their lines) on 804 / 115ac7c:
rts-ai-3's capital depots #3612 (platform x = 631, vertical), #6985 (y = -161) and #9834 (y = -159, placed at minute
41 beside #6985) share one block, and #9834's line #10 waits "busy" 23 times. The platforms are not joined end to end:
line #1 of #3612 runs south from its platform end and its curve at (631, -162) crosses the end of #6985's platform track
and the first curve of #6985's line #8 at (630, -161); line #10's first curves from #9834 at (620, -159) to (629, -153)
cross line #1 again. The AI's station-entry signal pairs stand one piece out of each platform (`survey_extract`: a pair
at piece 1's far end), so each crossing next to a platform falls into the platform's block, and every freight train
loading at one of the three platforms makes the others busy. 805 (18 busy waits) and rts-player's 23:00 pair in 804
show the same pattern. A rule against platforms beside other platforms (drafted: the AI keeps a new platform off
existing track) would not have changed this: the crossings are laid by the lines afterwards.

Proposals (AI behaviour, not done in this wave while r6-ai measures the AI; the 804 / 805 busy waits do not cost lines
or train items in the acceptance runs):
- put an AI line's station-entry pair at the platform joint itself (piece 1's start) instead of piece 1's far end, so a
  platform is a block of its own; every AI line's signals move, so M1 and M3 change and need the full acceptance;
- or signal pairs on both tracks around a crossing within 20 tiles of a platform end.

## 7. HUD Demolish tooltip for track (00796dd)

`hud.lua` `update_pieces` sets `rts.track-demolish-tooltip` ("Remove the selected track (Delete or Backspace, press
twice). Rails come back whole to the nearest stockpile; a signal goes with its partner on the other side of the track.
Rails under a train and depot platforms stay; a line between depots that loses a piece becomes plain track.") when the
selection holds an own rail or signal (`pieces.kind(e) == "track"`), else `rts.piece-demolish-tooltip` as before. The key
is in `locale/*/rails.cfg` (33d9846). r6-hud was told and leaves those lines alone.

## 8. #44 item 2: a second idle work train while a crew is out

The issue: "a construction train that is on a job keeps the one-crew rule; a second idle one is adopted when the first
is busy only if the lines are on separate track (else it waits with a reason)". Wave 1 kept one crew at a time.

**Change** (`dispatch_manual`, `J.any_idle_crew`, `J.apart`; `railgui.lua` `TRACK_WHY`; locale EN/RU):
- while a crew of the force is out (a construction train on a job), a player's track line still waits "crew-out" at once
  when no idle work train of the force stands on any depot's platform (the 0.1.4 wave 1 path, no path requests);
- when one does, the dispatch looks for a depot that reaches the line's start as before, and takes **only** an idle work
  train standing on that depot's platform (no new deploy), and only when `J.apart` holds: the rails of the work train,
  of its path to the line's start (`request_train_path`, type "path", `return_path`) and of the line's built pieces share
  nothing with any crew out (its train's rails, the path it drives, its path home to its depot's stops, its line's built
  pieces), and no planned piece of the two lines is the same. Plain player track has no signals, so two crews whose ways
  never touch never meet. Log `rails: track segment #N: the work train T standing on depot #D's platform is taken as its
  crew (a second crew: its way shares no track with construction train C on track line #L)`;
- otherwise the line waits "crew-out" (no idle work train at a depot that reaches it) or "crew-out-shared" ("a
  construction train is out on track line N, and the work train standing at your depot would share track with it";
  RU "путеукладчик работает на участке пути N, а рабочий поезд у вашего депо поехал бы по тем же рельсам"), shown in
  the depot panel's track rows; no "track not built" alert while a crew is out (as before).
- `dispatch_builder` (lines between depots) keeps one crew at a time for players.

**Tests** (fixture `r3_rails_manual.lua`, new stage `second` after `adopt`): depots K and M 80 tiles north of track 1,
not connected to each other; K's crew builds a 100-tile segment west of K; meanwhile segments from K's and M's east
ends are laid and handed over as planner track (both wait "crew-out"), then a work train is assembled at M and, once
K's platform is free, one at K. **second_crew**: M's work train is the crew of M's planner track while K's crew is
out; **second_shared**: K's planner track waits "crew-out-shared" (K's work train and K's crew both use K's platform),
K's work train is then disbanded (K's crew comes home onto that platform); **second_built**: both get built. Run
`r6-man6` (`scratchpad/r6-rails/run.sh manual r6-man6`): **32/32**; M's work train 186 is the crew of planner track #47
1 s after it was assembled while K's crew 181 (from K, depot #5660) is out; K's planner track waits "crew-out-shared"
(detail: line 44) 2 s after the segments were laid; both 19-piece tracks built 29 s after they were laid (K's by K's next
crew). A first version of the stage drew K's segment 200 tiles west: the survey ran it along track 1 (own track at
`REUSE_COST`), its crew came from depot A and went home there, and `J.apart` rightly let K's work train go at the same
time; the stage now keeps K's crew on K.

## 9. Identity, saves and the Skirmish matrix on the final tree

The final tree is the branch head's mod (`build/trees/r6-final` in the worktree: 33d9846, 00796dd, 962b9e3, c671b64,
cb9a7da, dd408c1 and 4f0e775).

| What | Command | Result |
|---|---|---|
| M1 seed 501 against 115ac7c | `scratchpad/r6-rails/m1.sh r6-m1-final build/trees/r6-final/mods/factorio-rts` | **line-identical**: 68,801 lines each, 0 differing, no depot removed or lost. Headless runs have no player force, so #45's player paths and #44 item 2 never run; the stranded-train rule needs a lost depot, which M1 501 never has |
| M3 801-805 against 115ac7c | `PAR=2 scratchpad/r6-rails/accept-bench.sh r6c-final build/trees/r6-final/mods/factorio-rts` | acceptance criteria as on 115ac7c and the 0.1.3 acceptance (Age III 5/5, linked 12/20, aggressive first line 3/5, P/P/P/P, 0 starving, 0 errors); items by train 213,347 -> 215,751 (802 34,683 -> 37,163, +7.2 %; 805 41,100 -> 41,024; 801, 803, 804 equal); 3 stranded trains scrapped (802: rts-player's 62 and rts-ai-1's 240, which c671b64 alone could not place; 805: rts-ai-2's 160) |
| The 4 owner saves | `scratchpad/r6-rails/saves.sh build/trees/r6-final/mods 100 r6sfin` | **0 errors** in all four (483, 602, 572, 637 `[rts]` lines in 100 s); `owner-0114-now.zip`: planner track #38 turned round and work train 97 taken as its crew at 11 s as in wave 1, #39 waits "crew-out 38" (no second idle work train there); `owner-0113-now.zip`: the #41 signal repair 48 -> 14 as in wave 1; no orphan platform in any |
| Skirmish identity matrix (10 runs, seed 777) against base0111 | `scratchpad/r6-rails/matrix.sh r6mx build/trees/r6-final/mods/factorio-rts` (`KEEP_TREE=<tree> SEED=777 JOBS=1 tools/autotest-matrix.sh r6mx; tools/matrix-compare.sh base0111 r6mx`) | **0 differing lines** in all 10 scenarios (1v3 stress 36/38 as base0111, the rest all passed, 0 Lua errors) |
| Smoke | `run.sh smoke r6-smoke-final build/trees/r6-final/mods/factorio-rts` | 65/65, 0 errors |

## 10. Open items

- **AI platforms in one block** (section 6): station-entry pairs at the platform joint, or signals around crossings
  next to platforms; an AI change for the acceptance runs. The 804 / 805 busy waits (24, 18) stay.
- **A crew comes home onto a platform where a work train stands**: the player can still assemble a work train on a
  platform while that depot's crew is out (the human busy rule only refuses while a train's path ends on the platform);
  the crew then drives into it on unsignalled track. Item 2 does not send that work train (it shares the crew's track),
  but nothing keeps the player from parking it there. A deploy check "a crew of this depot is out" would.
- **A player's depot rebuilt on the old site** of a destroyed one does not take the old platform (now plain track) as
  its own: `spec_fits` refuses rails on rails, so the new depot lays its platform on another side or finds no room (the
  AI's `reuse_site` does this for the AI only). Delete removes the old platform first.
- **Elevated track of a dissolved line** (Bridges): `rails.remove_track` takes ground rails and signals only; elevated
  rails, ramps and supports of a dissolved line stay as they are.
- **The stranded-train rule** covers AI freight trains of a line no live program holds; a player's freight trains run on
  stop lists, which skip a gone depot (`railroutes.refresh`) as before.
- **A lone 0.1.2 Rail tool segment with bridges** stays out of Delete (its supports would be lost by the split), as in
  wave 1.

## 11. Proposed changelog lines

```
Features:
  - Railways: demolishing a rail depot takes its platform with it: the platform rails, its two stops and the signals next
    to them go, and half of the rails come back with the depot's refund. Its lines to other depots stay on the ground as
    plain track of yours that Delete removes. A depot with a train on its platform, or a station with a train at its
    stop, is not demolished until the train has gone ("Depot 2 cannot be demolished: train 97 stands on its platform").
    (#45)
  - Railways: the track of a line between depots can be removed with Delete (also your own track such a line runs
    along): the line becomes plain track that no construction train repairs any more, and a message names it. (#33)
  - Railways: while a construction train is out, a work train you assembled (Construction) on another depot's platform
    goes as a second crew when its way and the track it builds share no rail with the crew out; otherwise the depot panel
    says the track waits because the work train would share track with the crew. (#44)

Changes:
  - Railways: a depot of yours that is destroyed leaves its platform as plain track of yours, and its lines between
    depots become plain track too. A save from before 0.1.4 gets this for the depots it lost when it loads. (#45)
  - HUD: the Demolish button of selected track says that rails come back whole (it said "half of the recipe cost"). (#33)

Bugfixes:
  - AI: a freight train of a rail line the AI had given up (its far city lost, its far depot destroyed) stood without a
    path on its platform for the rest of the match, and a new line crossing that platform never opened (M3 seed 802:
    every construction train waited at the signal before it). Such a train is now scrapped after 3 minutes. (#33)
```
