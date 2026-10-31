# Release 0.1.4: plan (rolling)

Date: 2026-10-31. Base: `main` at 5fd9581 (release 0.1.3, mod tree 61d6f05). Engine: Factorio 2.1.23 (Steam,
mac-arm64), Space Age on by default. Milestone: https://github.com/Kealman/factorio-rts/milestone/4.

## 1. Goal

A rolling milestone: the owner plays 0.1.3, the notes become issues, and waves run on what has accumulated. This first
wave takes what is in the milestone now; the release is not closed by it. When the wave lands, the lead installs the
tree into the owner's mods folder as a 0.1.4 development build, the owner plays on, and the next notes join the same
milestone.

## 2. Assignment

| Agent | Model | Issues | Main files |
|---|---|---|---|
| `r5-rails` | Opus | #41 (chain-signal pairs at every join, the construction train with no path home, removable signals), #33 (first item 6 "remove built track", then item 4 busy platforms and the AI crews that stand still, then item 3 overlapping surveys) | `scripts/rails.lua`, `scripts/railplan.lua`, `scripts/railroutes.lua`, `scripts/railgui.lua`, `scripts/pieces.lua`, `scripts/selection.lua`, `scripts/demolish.lua` |
| `r5-hud` | Sonnet | #42 (signals and the Station on the Logistics tab, the help card on signalling), #40 (GUI cosmetics) | `scripts/hud.lua`, `scripts/help.lua`, `scripts/helpgui.lua`, `scripts/stripgui.lua`, locale |
| `r5-ai` | Opus | #39 (AI copper in Age I), #2 (rail linking) | `scripts/ai/*`, `balance.lua` (AI keys), `scripts/rails.lua` AI program section |
| lead | Fable | integration, identity, owner-save checks, the development install, later the acceptance and the release | |

## 3. Rules

Every rule of `docs/qa/release-0-1-2-plan.md` section 3 and the differences of `docs/qa/release-0-1-3-plan.md`
section 3 apply (own worktree and branch, no push, no amend, English, locale EN+RU, smoke before each commit,
Skirmish identity against `base0111` on a frozen tree, `pgrep -f start-server | wc -l` under 5 with `r5-ai` at most 3
and the others 1, Bash calls under 10 minutes, notes `docs/qa/release-0-1-4-<agent>-notes.md`, terse messages). For
this wave:

1. **Screen owner is `r5-rails`.** `r5-hud` asks it for GUI slots. Before any GUI run check that no other Factorio
   client runs (`ps -axo command | grep "[M]acOS/factorio" | grep -v start-server`): the owner may start playing at
   any time, and then GUI runs wait.
2. **Fixtures.** The owner's current save `/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/saves/owner-0113-now.zip`
   (0.1.3, minute 85, the planner track with the signal clusters and construction train 76 in `no_path` at
   (328.8, -63.2): the fixture of #41; copy it, never edit it), plus `owner-0112.zip` and `owner-0111-age2.zip`. All
   three must load on your tree without errors; the lead's helper is
   `scratchpad/lead/owner-save-load*.sh` in the session scratchpad, and the lead's diagnostic module for #41 is
   `/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/trees/diag-mods/factorio-rts/scripts/diag_owner.lua`
   (its output: `build/owner-now-diag2-server.log` in the main checkout). The frozen 0.1.3 tree is
   `/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/trees/61d6f05/mods/factorio-rts` (A side of every
   before/after comparison).
3. **AI identity:** `r5-rails` and `r5-hud` keep the M1 seed-501 Nation run line-identical to the 0.1.3 tree (only the
   stagger-phase listing lines may differ). `r5-ai` changes the AI on purpose and reports against the 0.1.3
   acceptance `build/release-check/2026-10-28_0145/REPORT.md` in the main checkout: M1 501 53/53 and 25,678 train
   items (keep both), Age III by 40:00 5 of 5 (keep), linked by 35:00 12 of 20 (target 16), aggressive first line
   3 of 5 (target 4), no capital lost, capital starving minutes 0.
4. **Version:** leave `info.json` at 0.1.3 and the changelog alone; the lead bumps to 0.1.4 for the development install
   and writes the changelog from your notes.
5. **The owner's save must come out better, not only loadable:** on `owner-0113-now.zip` after #41, the surplus
   signals are gone, train 76 paths home or the log says why, and the owner's unbuilt rail-signal ghosts stay.
