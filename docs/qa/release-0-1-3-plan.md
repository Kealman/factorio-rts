# Release 0.1.3: plan

Date: 2026-10-27. Base: `main` at d51b6ab (release 0.1.2, mod tree ac55c09). Engine: Factorio 2.1.23 (Steam,
mac-arm64), Space Age on by default. Milestone: https://github.com/Kealman/factorio-rts/milestone/3.

## 1. Goal

The owner's second real session (0.1.2) stopped at "hard to play without railways": the click-waypoint Rail tool does
not join segments and is clumsy. 0.1.3 brings the vanilla rail planner back, fixes the factory page overflow, makes the
top strip configurable, removes release numbers from player text, clears the GUI cosmetics and the rails follow-ups,
and gives the Nation AI its pace work.

## 2. Assignment

| Agent | Model | Issues | Main files |
|---|---|---|---|
| `r4-rails` | Opus | #37 vanilla rail planner (investigate first, then build), then #33 rails follow-ups | `scripts/camera.lua`, `scripts/cursor.lua`, `scripts/rails.lua`, `scripts/railtool.lua` (to remove or hide), `scripts/railroutes.lua`, `scripts/railgui.lua`, `prototypes/rails.lua`, README rail section |
| `r4-hud` | Sonnet | #35 factory page overflow (first), #36 no version numbers in player text, #38 configurable top strip, #34 GUI cosmetics | `scripts/hud.lua`, `scripts/help.lua`, `scripts/helpgui.lua`, `scripts/itempicker.lua`, `scripts/objectives.lua`, locale, `tools/locale-probe/` |
| `r4-ai` | Opus | #20 AI follow-ups, #2 aggressive AI rail linking | `scripts/ai/*`, `balance.lua` (AI keys), `docs/qa/phase5-ai3-notes.md` |
| lead | Fable | integration, identity, acceptance (`tools/release-check.sh`), owner-save check, changelog, version 0.1.3, release, install, portal | `changelog.txt`, `CHANGELOG.md`, `README.md`, `docs/FEATURES.md`, `info.json` |

#15 (Windows) stays a tester item.

## 3. Rules

Every rule of `docs/qa/release-0-1-2-plan.md` section 3 applies (own worktree and branch, no push, no amend, English,
locale EN+RU, smoke before each commit, Skirmish identity against `base0111` with a frozen tree, server budget
`pgrep -f start-server | wc -l` under 5, Bash calls under 10 minutes, helper scripts under the scratchpad folder named
after the agent, notes `docs/qa/release-0-1-3-<agent>-notes.md` with proposed changelog lines, terse messages to the
lead). Differences for this wave:

1. **Screen owner is `r4-rails`** (the planner work is real-input GUI work). `r4-hud` asks "GUI slot: <purpose>,
   <minutes>" and waits for "go"; `r4-ai` needs no GUI. Before any GUI run check that no other Factorio client runs
   (`ps -axo command | grep "[M]acOS/factorio" | grep -v start-server`); the owner's own game would be one, and then
   the run waits.
2. **Servers:** `r4-ai` may use up to 3 headless servers at a time, the others 1 each (2 briefly for the identity
   matrix with `JOBS=2`). Nation acceptance runs are long: `r4-ai` schedules them so the machine never has more than 5.
3. **Fixtures:** the owner's 0.1.2 save `/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/saves/owner-0112.zip`
   (a new game played on 0.1.2 for about 40 minutes; copy it, never edit it) and the 0.1.1 Age II save
   `owner-0111-age2.zip`; both must load on your tree without errors (120 s headless; the helper
   `scratchpad/lead/owner-save-load.sh` in the session scratchpad shows the call), and the 0.1.2 one is where the owner
   continues, so its tool-laid track, trains and stop lists must survive #37. The frozen 0.1.2 tree is
   `/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/trees/ac55c09/mods/factorio-rts` (A side of every
   before/after comparison: `tools/determinism-compare.sh` with `KEEP_TREE=<that>` and `TREE_B=<yours>`, `WHAT=all`).
4. **AI identity:** `r4-rails` and `r4-hud` must keep the M1 seed-501 Nation run line-identical to the 0.1.2 tree
   (60 minutes; only the stagger-phase listing lines may differ). `r4-ai` changes the AI on purpose and reports the
   0.1.2 acceptance numbers against its own: M1 501 (train items 19,101; 51/53), M3 801-805 (Age III by 40:00 2 of 5,
   linked 9 of 20, aggressive first line 4 of 5) from `build/release-check/2026-10-26_2137/REPORT.md` in the main
   checkout; its targets are the report's: train items ≥ 20,000, Age III ≥ 3 of 5, linked ≥ 16 of 20.
5. **Merging:** the lead merges each agent's commits into `main` as they land and may ask you to `git merge main`
   into your branch mid-wave; `hud.lua` is shared by `r4-hud` and `r4-rails` (the Rail button and the build menu):
   keep hunks small and merge main when asked.

## 4. Acceptance (lead)

Skirmish identity against 0.1.1, `tools/release-check.sh` on the merged tree against the 0.1.2 report, both owner saves
loaded 10 minutes headless with 0 errors, GUI pass EN/RU with the new strip, factory page and planner, Linux Docker
smoke, then version 0.1.3, changelog, package, GitHub release, install, Mod Portal.
