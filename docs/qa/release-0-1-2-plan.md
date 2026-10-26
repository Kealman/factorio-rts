# Release 0.1.2: plan and working rules

Date: 2026-10-26. Base: `main` at 43a8581 (mod tree 615854f, version 0.1.1). Engine: Factorio 2.1.23 (Steam, mac-arm64),
Space Age on by default. Owner feedback from the first real 0.1.1 session (reached Age II, then stopped: "what I described
blocks play; fix it first") is milestone 0.1.2 on GitHub: https://github.com/Kealman/factorio-rts/milestone/2.

## 1. Goal

Make the player's own building, demolition and logistics understandable and controllable, and give railways back to the
player. Everything the owner hit in play is in issues #22 to #32; the AI pace items (#2, #20) and Windows (#15) follow
once the play blockers are in.

## 2. Assignment

| Agent | Model | Issues | Main files |
|---|---|---|---|
| `r3-build` | Sonnet | #23 select / demolish belts, inserters, poles; #27 cancel ghosts; #25 underground belts, splitters, long inserters | `scripts/selection.lua`, `scripts/demolish.lua`, `scripts/hud.lua` (building page, build menu), `prototypes/recipes.lua`, locale |
| `r3-orders` | Sonnet | #22 craft queue (click 1 / Shift 5 / Ctrl all, endless as a toggle); #24 clear trees and rocks; #21 town supply routes burn coal | `scripts/production.lua`, `scripts/hud.lua` (recipe grid), `scripts/orders.lua`, `scripts/units.lua`, `scripts/logistics.lua` |
| `r3-ux` | Sonnet | #30 help cards (Shift hover, ? button, build tooltips); #28 refinery and pumpjack without pipes; #29 recipe names (unknown key); #26 new city's robots and starter stock; #19 objectives log noise | new `scripts/help.lua`, `scripts/hud.lua` (tooltips, panels), `scripts/hubgui.lua`, `scripts/citygui.lua`, `scripts/districts.lua`, `scripts/cities.lua`, `prototypes/age2.lua`, `scripts/objectives.lua`, locale |
| `r3-rails` | Opus | #31 player-built railways and multi-stop schedules (part B first, then A); #32 train builder | `scripts/rails.lua`, `scripts/railgui.lua`, `scripts/trainswar.lua`, `scripts/garrison.lua`, `prototypes/rails*.lua`, `scripts/hud.lua` (build menu items), locale |
| lead | Fable | integration, Skirmish identity, owner-save check, acceptance (`tools/release-check.sh`), changelog, version 0.1.2, release, install, portal | `changelog.txt`, `CHANGELOG.md`, `README.md`, `docs/FEATURES.md`, `info.json` |

Later in the milestone (after the four above land): `r3-ai` (Opus) on #20 and #2.

## 3. Rules for every agent

1. **Own worktree, own branch.** Each agent works in its own git worktree and branch and never touches `main`. Commit
   often, one issue or one coherent step per commit, message in English with `Closes #N` or `Refs #N`. Never amend a
   commit, never rebase a pushed one, never push: the lead merges into `main` and pushes.
2. **English only** in code, comments, commit messages, docs and file names. Follow the module header style
   (a contract comment at the top of each module) and log QA-readable `[rts]` lines through `util.log`.
3. **Locale**: every new string in `locale/en/*.cfg` and `locale/ru/*.cfg` in the same commit. The RU text had a full
   review in 0.1.1; keep its tone (see the existing keys of the same file).
4. **Saves from 0.1.1: nice to have, not a constraint.** The owner is happy to start a new game if 0.1.2 changes the
   rules, so do not bend a design to keep old storage alive. Still, a 0.1.1 save must not crash on load: keep `init()`
   idempotent, create new storage fields lazily, and when a save cannot keep an old structure, drop or reset it cleanly
   with a `[rts]` log line that says what was reset. The owner's Age II save
   `/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/saves/owner-0111-age2.zip` (read-only: copy it) is the
   fixture for that check: before the last commit of an issue, start a headless server on a copy with your tree (the
   `--start-server` call in `tools/saveload-check.sh` shows how) for 120 s and report errors, if any, and what was
   reset, in your notes. A breaking change is fine when the notes and the proposed changelog line say so.
5. **Skirmish stays byte-identical** unless your issue is about Skirmish behaviour. The lead ran
   `SEED=777 JOBS=3 tools/autotest-matrix.sh base0111` on the 0.1.1 tree; the result is
   `/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/matrix-base0111`. Symlink it into your worktree's
   `build/`, run `SEED=777 JOBS=2 tools/autotest-matrix.sh <your-tag>` on your tree, then
   `tools/matrix-compare.sh base0111 <your-tag>`: 0 differing lines, GUI-only lines and the trailing wall-clock
   "spawned" line excepted. Report the result in your notes. A new recipe or prototype changes only the static counts,
   which the compare normalises.
6. **Smoke before every commit:**
   `tools/autotest-run.sh smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240`
   (65/65, 0 errors). Nation changes also run a Nation match of the area touched with the fixture that covers it
   (`tools/probes/`), and `tools/saveload-check.sh` when storage changed.
7. **Machine budget.** At most 5 headless servers run on this machine at once, shared by everyone: check
   `pgrep -fc "start-server"` (macOS pgrep takes no `--`) before a run and wait while it is 5 or more. Normally one server per agent; the
   identity matrix may use `JOBS=2`. Every `Bash` call must return within 10 minutes: run long jobs with
   `run_in_background` or in a foreground loop that polls the log and exits before the limit. Benchmarks taken under
   load are upper bounds only.
8. **One GUI client at a time; `r3-ux` owns the screen.** Before any GUI run another agent sends `r3-ux` a message
   "GUI slot: <purpose>, <minutes>" and waits for "go"; slots stay under 20 minutes; afterwards the agent reports
   "GUI slot released". `r3-ux` answers such requests within a few minutes and never leaves a client running idle.
   GUI runs use `tools/gui-run.sh` with a 1280x800 window at UI scale 0.75 and screenshots go under your worktree's
   `build/shots-<agent>-*/`.
9. **Helper scripts** live under the session scratchpad in a folder named after the agent
   (`/private/tmp/claude-501/-Users-evgeniyivanov-Projects-home-games-factorio-rts/<session>/scratchpad/<agent>/`), or
   under `tools/probes/` when they are test fixtures worth keeping (English, with a header that says how to run them).
10. **Notes.** Each agent writes `docs/qa/release-0-1-2-<agent>-notes.md`: what changed per issue, how it was tested
    (commands, numbers, screenshots), the identity and save-load results, open items, and a block of proposed
    `changelog.txt` lines per category. The lead writes the changelog.
11. **Talk tersely.** Send the lead a message when an issue is done (commit hash, one line of result), when blocked,
    and when a decision is needed; propose a default with every question. Decisions arrive as short messages; answer
    with a one-line ack. Do not wait idle for an answer when other work of yours can go on.
12. **Design questions** are decided by the issue text first, then the existing contracts (`docs/PHASE*.md`,
    `docs/SCALE-VISION.md`), then the lead. Keep the AI's behaviour unchanged unless the issue says otherwise; the
    5-seed Nation acceptance numbers of 0.1.1 are in `build/release-check/2026-10-25_1305/REPORT.md`.

## 4. Acceptance (lead, after the merge)

Skirmish identity against 0.1.1, `tools/release-check.sh` on the merged tree (compare with the 0.1.1 report), the
owner's save loaded and played 10 minutes headless with 0 errors, GUI pass EN/RU with the new panels, Linux Docker
smoke, then version 0.1.2, changelog, package, GitHub release, install into the real mods folder, Mod Portal upload.
