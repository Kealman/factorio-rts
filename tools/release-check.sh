#!/usr/bin/env bash
# Release acceptance in one command (issue #18; the order of docs/qa/phase5-m3-integration-notes.md section 9). Runs every
# headless stage on a frozen `git archive` copy of REV (default HEAD) and writes build/release-check/<date>/REPORT.md with
# a pass/fail table and the numbers (tools/release-check.py builds it from the logs; rerun it any time).
#
# Usage: tools/release-check.sh                     every default stage, at most SERVERS servers at a time
#        STAGES="m1 det" tools/release-check.sh     only those stages
#        RC_DIR=build/release-check/<date> tools/release-check.sh    resume: finished jobs are kept (FORCE=1 reruns them)
#        STAGES=report RC_DIR=... tools/release-check.sh            rebuild REPORT.md only
#        QUICK=1 SERVERS=2 tools/release-check.sh   a dry run with short durations, one seed per set and two matrix
#                                                   scenarios: it proves the script and the parsers, not the criteria
# Stages (default: smoke matrix m1 m2 m3 w3072 debt warpaths sl det scene):
#   smoke    the Skirmish smoke (legacy units, seed 9090): 65/65 and 0 errors; a failure stops the check (CONTINUE=1 goes on)
#   matrix   tools/autotest-matrix.sh with SEED=777 on the tree and on the baseline, then a line-by-line comparison
#            (tools/matrix-compare.sh's normalisation). The baseline is the matrix tag BASE_TAG (default m3i-p21) when its
#            ten server logs still exist in build/, else the tree of BASE_REV (default v0.1.0) run once into the tag
#            rcbase-<rev> (kept in build/ for later checks). Differing lines whose class (first word) is in GUI_CLASSES
#            are listed and allowed; any other differing line fails the stage.
#   m1       M1 acceptance (seed 501, tools/probes/m1_acceptance.lua, 60 min) twice, at SPEED 8 and 10: score, train
#            items (>= 20,000, #7) and 0 differing lines between the two runs
#   m2       seeds 701-705, m3       seeds 801-805: tools/probes/m3_acceptance.lua, 4 normal AIs, 2048, 60 min, SPEED 8
#            (the last 5 minutes at speed 1 for the UPS lines); per-seed criteria in the report
#   w3072    one 3072x4 world (map seed SEED_3072, default 30724) with the same probe: holds, air, artillery present (#4)
#   debt     the debt path (#5): tools/probes/ai3_debt.lua holds the largest army's nation in debt from minute 22
#            (seed 801, SPEED 10, 34 minutes): stage 2 reached, the army retired to keep_supply, no regrowth
#   warpaths the council's war paths (#4): tools/probes/ai3_war_paths.lua, 1v1 hard, seed 811, SPEED 10: 6/6
#   sl       save at minutes 20 and 40 (seed 802), load, play on: 0 errors in both halves, same state after both loads
#   det      determinism: seeds 801 and 802, two runs of 30 minutes each, event lines compared (0 differing)
#   scene    the perf scene (tools/perf-bench.sh scene, seed 701, 5 benchmark minutes, 5 realtime minutes). It waits up to
#            SCENE_WAIT seconds (default 3600) until no other Factorio process runs, because a bench under load only gives
#            upper bounds; after the wait it runs anyway and the report says it ran under load.
#   lan, heavy  GUI clients on this Mac's screen and Steam: never in the default set; the lead runs STAGES="lan heavy"
#            when the screen is free (tools/lan-check.sh 10 minutes with two clients, tools/heavy-mode.sh 10 minutes).
#   report   REPORT.md (always runs last).
# Outside this script: the GUI pass in English and Russian and the Codex GUI QA protocol (docs/qa/phase5-m3-protocol.md).
#
# Env: REV (default HEAD), STAGES, SERVERS (default 4), RC_DIR, QUICK, FORCE, CONTINUE, BASE_TAG, BASE_REV, GUI_CLASSES,
#      SEED_3072, SCENE_WAIT. Run names start with rc-<date>- in build/ (logs: build/<run>-server.log).
# Wall clock with SERVERS=4: about 2.5 hours (+30 minutes the first time the baseline matrix is built), and the scene
# wait. Foreground: keep the terminal open (the jobs are children of this script).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
source tools/factorio-env.sh
REV="${REV:-HEAD}"; SERVERS="${SERVERS:-4}"; QUICK="${QUICK:-}"
STAGES="${STAGES:-smoke matrix m1 m2 m3 w3072 debt warpaths sl det scene}"
RC_DIR="${RC_DIR:-build/release-check/$(date +%Y-%m-%d_%H%M)}"
mkdir -p "$RC_DIR"; RC_DIR="$(cd "$RC_DIR" && pwd)"
P="rc-$(basename "$RC_DIR" | tr -c 'A-Za-z0-9\n' '-')" # run-name prefix
BASE_TAG="${BASE_TAG:-m3i-p21}"; BASE_REV="${BASE_REV:-v0.1.0}"
GUI_CLASSES="${GUI_CLASSES:-hud camera lobby selection cursor citygui hubgui railgui techgui marketgui diplomacygui ledgergui divisiongui abilitygui itempicker menu objectives onboarding gui}"
NATION4='{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}'
NATION4_3072='{opponents = 3, difficulty = "normal", mode = "nation", world_size = 3072, enemy_brain = "ai"}'
NATION1='{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}'
SMOKE='{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}'
if [ -n "$QUICK" ]; then # durations for a dry run of the script itself
  DUR=6; ACC_CAP=1200; M1_CAP=1200; M3_SEEDS="801"; M2_SEEDS="701"; SL_MINUTES="2 4"; SL_AFTER=60
  DET_SEEDS="801"; DET_MIN=3; MX_FILTER="legacy-units"; SCENE_ENV="SCENE_AT=2 REALTIME=2"; SCENE_MIN=1
  SCENE_WAIT="${SCENE_WAIT:-0}"
else
  DUR=60; ACC_CAP=12000; M1_CAP=4800; M3_SEEDS="801 802 803 804 805"; M2_SEEDS="701 702 703 704 705"
  SL_MINUTES="20 40"; SL_AFTER=400; DET_SEEDS="801 802"; DET_MIN=30; MX_FILTER=""; SCENE_ENV="REALTIME=5"; SCENE_MIN=5
  SCENE_WAIT="${SCENE_WAIT:-3600}"
fi
has() { case " $STAGES " in *" $1 "*) return 0;; esac; return 1; }
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$RC_DIR/progress.log"; }
manifest() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$RC_DIR/runs.tsv"; } # id kind run-name extra
slots() { while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$1" ]; do sleep 5; done; }
# job <id> <kind> <run-name> <extra> <command...>: runs in the background into <RC_DIR>/<id>.txt, its exit status into
# <id>.rc; a job whose .rc exists is kept (resume) unless FORCE=1
job() {
  local id="$1" kind="$2" run="$3" extra="$4"; shift 4
  grep -q "^$id"$'\t' "$RC_DIR/runs.tsv" 2>/dev/null || manifest "$id" "$kind" "$run" "$extra"
  if [ -f "$RC_DIR/$id.rc" ] && [ -z "${FORCE:-}" ]; then log "$id: kept from before (exit $(cat "$RC_DIR/$id.rc"))"; return; fi
  rm -f "$RC_DIR/$id.rc"
  slots "$SERVERS"
  log "start $id ($run)"
  ( "$@" > "$RC_DIR/$id.txt" 2>&1; rc=$?; echo "$rc" > "$RC_DIR/$id.rc"; log "done $id (exit $rc)" ) &
  sleep 3
}
archive_tree() { # <rev> <dir>: git archive of mods/factorio-rts into <dir>/factorio-rts (once)
  [ -f "$2/factorio-rts/info.json" ] && return 0
  rm -rf "$2"; mkdir -p "$2/tmp"
  git archive "$1" mods/factorio-rts | tar -x -C "$2/tmp" || return 1
  mv "$2/tmp/mods/factorio-rts" "$2/factorio-rts"; rm -rf "$2/tmp"
}

# --- the tree and the run info
REV_HASH="$(git rev-parse --short "$REV^{commit}")" || { echo "unknown REV $REV"; exit 2; }
T="$RC_DIR/tree/factorio-rts"
archive_tree "$REV" "$RC_DIR/tree" || { echo "git archive of $REV failed"; exit 2; }
if [ ! -f "$RC_DIR/info.env" ]; then
  {
    echo "REV=$REV"; echo "REV_HASH=$REV_HASH"; echo "REV_SUBJECT=$(git log -1 --format=%s "$REV" | tr -d '\n' | cut -c1-140)"
    echo "MOD_VERSION=$(sed -nE 's/.*"version": *"([^"]+)".*/\1/p' "$T/info.json" | head -1)"
    echo "FACTORIO=$("$FACTORIO_BIN" --version 2>/dev/null | head -1)"
    echo "UNCOMMITTED_MODS=$(git status --porcelain mods | wc -l | tr -d ' ')"
    echo "STARTED=$(date '+%Y-%m-%d %H:%M')"; echo "QUICK=$QUICK"; echo "PREFIX=$P"
  } > "$RC_DIR/info.env"
fi
TREE_HASH="$(sed -n 's/^REV_HASH=//p' "$RC_DIR/info.env")" # a resumed check keeps the tree it started with
[ "$TREE_HASH" != "$REV_HASH" ] && echo "note: resuming the tree of $TREE_HASH; $REV now points at $REV_HASH"
REV_HASH="$TREE_HASH"
echo "SERVERS=$SERVERS" > "$RC_DIR/info-run.env"; echo "STAGES=$STAGES" >> "$RC_DIR/info-run.env"
echo "GUI_CLASSES=$GUI_CLASSES" >> "$RC_DIR/info-run.env"
log "release check $(basename "$RC_DIR"): $REV = $REV_HASH, stages: $STAGES, servers $SERVERS${QUICK:+, QUICK dry run}"

# --- smoke (a gate)
if has smoke; then
  job smoke smoke "$P-smoke" "" env KEEP_TREE="$T" SEED=9090 tools/autotest-run.sh "$P-smoke" "$SMOKE" 600
  wait
  if ! grep -q "autotest summary 65/65 (all passed)" "$RC_DIR/smoke.txt" || ! grep -A1 "=== errors ===" "$RC_DIR/smoke.txt" | grep -q "(none)"; then
    log "smoke FAILED: $(grep -E 'autotest summary' "$RC_DIR/smoke.txt" | tail -1)"
    [ -n "${CONTINUE:-}" ] || { python3 -I tools/release-check.py "$RC_DIR" > "$RC_DIR/REPORT.md"; log "stopped; report: $RC_DIR/REPORT.md"; exit 1; }
  fi
fi

# --- Skirmish matrix against the baseline
if has matrix; then
  scen_names() { sed -n '/^SCENARIOS=(/,/^)/p' tools/autotest-matrix.sh | grep -oE '^  "[a-z0-9-]+' | tr -d ' "' \
    | while read -r s; do [ -z "$MX_FILTER" ] || [[ "$s" == *$MX_FILTER* ]] && echo "$s"; done; }
  have_logs() { local s; for s in $(scen_names); do [ -f "build/mx-$1-$s-server.log" ] || return 1; done; return 0; }
  BASE="$BASE_TAG"
  if ! have_logs "$BASE"; then
    BASE_HASH="$(git rev-parse --short "$BASE_REV^{commit}")" || { echo "unknown BASE_REV $BASE_REV"; exit 2; }
    BASE="rcbase-$BASE_HASH"
    if ! have_logs "$BASE"; then
      archive_tree "$BASE_REV" "build/release-check/base-$BASE_HASH" || { echo "git archive of $BASE_REV failed"; exit 2; }
      log "baseline matrix $BASE: $BASE_TAG has no logs in build/, running $BASE_REV ($BASE_HASH) once"
      JOBS="$SERVERS" SEED=777 KEEP_TREE="$ROOT/build/release-check/base-$BASE_HASH/factorio-rts" \
        tools/autotest-matrix.sh "$BASE" $MX_FILTER > "$RC_DIR/matrix-base.txt" 2>&1
    fi
  fi
  { echo "MATRIX_BASE=$BASE"; echo "MATRIX_BASE_WANTED=$BASE_TAG"; echo "MATRIX_HEAD=$P-mx"
    [ "$BASE" != "$BASE_TAG" ] && echo "MATRIX_BASE_REV=$BASE_REV ($BASE_HASH)"
    echo "MATRIX_SCENARIOS=$(scen_names | tr '\n' ' ')"; } > "$RC_DIR/matrix.env"
  if [ -f "$RC_DIR/matrix.rc" ] && [ -z "${FORCE:-}" ]; then log "matrix: kept from before"; else
    log "matrix $P-mx (seed 777) against $BASE"
    JOBS="$SERVERS" SEED=777 KEEP_TREE="$T" tools/autotest-matrix.sh "$P-mx" $MX_FILTER > "$RC_DIR/matrix.txt" 2>&1
    echo $? > "$RC_DIR/matrix.rc"
  fi
  tools/matrix-compare.sh "$BASE" "$P-mx" 12 > "$RC_DIR/matrix-compare.txt" 2>&1
fi

# --- the long runs, at most SERVERS at a time, longest first
if has sl; then for m in $(echo "$SL_MINUTES" | tr ' ' '\n' | sort -rn); do
  job "sl$m" sl "$P-sl$m" "minute=$m" env SAVE_MINUTE="$m" SPEED=8 DURATION_MIN="$DUR" SEED=802 KEEP_TREE="$T" \
    tools/saveload-check.sh "$P-sl$m" "$NATION4" "$SL_AFTER"
done; fi
if has det; then for s in $DET_SEEDS; do
  job "det$s" det "$P-det-$s" "seed=$s" env WHAT=events KEEP_TREE="$T" tools/determinism-compare.sh "$P-det-$s" "$NATION4" "$DET_MIN" "$s"
done; fi
if has m3; then for s in $M3_SEEDS; do
  job "m3-$s" m3 "$P-m3-$s" "seed=$s" env PERF=1 KEEP_TREE="$T" EXTRA_LUA=tools/probes/m3_acceptance.lua DURATION_MIN="$DUR" \
    SEED="$s" SPEED=8 tools/autotest-run.sh "$P-m3-$s" "$NATION4" "$ACC_CAP"
done; fi
if has m2; then for s in $M2_SEEDS; do
  job "m2-$s" m2 "$P-m2-$s" "seed=$s" env PERF=1 KEEP_TREE="$T" EXTRA_LUA=tools/probes/m3_acceptance.lua DURATION_MIN="$DUR" \
    SEED="$s" SPEED=8 tools/autotest-run.sh "$P-m2-$s" "$NATION4" "$ACC_CAP"
done; fi
if has w3072; then
  job w3072 w3072 "$P-w3072" "seed=${SEED_3072:-30724}" env PERF=1 KEEP_TREE="$T" EXTRA_LUA=tools/probes/m3_acceptance.lua \
    DURATION_MIN="$DUR" SEED="${SEED_3072:-30724}" SPEED=8 tools/autotest-run.sh "$P-w3072" "$NATION4_3072" "$ACC_CAP"
fi
if has debt; then
  job debt-801 debt "$P-debt-801" "seed=801" env KEEP_TREE="$T" EXTRA_LUA=tools/probes/ai3_debt.lua DURATION_MIN=34 SEED=801 \
    SPEED=10 tools/autotest-run.sh "$P-debt-801" "$NATION4" 4000
fi
if has warpaths; then
  job warpaths-811 warpaths "$P-warpaths-811" "seed=811" env KEEP_TREE="$T" EXTRA_LUA=tools/probes/ai3_war_paths.lua \
    STOP_ON=RTS_WARPATHS_DONE DURATION_MIN=50 SEED=811 SPEED=10 tools/autotest-run.sh "$P-warpaths-811" \
    '{opponents = 1, difficulty = "hard", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 3000
fi
if has m1; then for sp in 8 10; do
  job "m1-s$sp" m1 "$P-m1-s$sp" "speed=$sp" env PERF=1 KEEP_TREE="$T" EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN="$DUR" \
    SEED=501 SPEED="$sp" tools/autotest-run.sh "$P-m1-s$sp" "$NATION1" "$M1_CAP"
done; fi
wait

# --- the perf scene, alone on the machine if it gets quiet within SCENE_WAIT
if has scene; then
  if [ -f "$RC_DIR/scene.rc" ] && [ -z "${FORCE:-}" ]; then log "scene: kept from before"; else
    others() { pgrep -f 'MacOS/factorio' | wc -l | tr -d ' '; }
    W0=$(date +%s)
    while [ "$(others)" -gt 0 ] && [ $(( $(date +%s) - W0 )) -lt "$SCENE_WAIT" ]; do
      [ $(( ( $(date +%s) - W0 ) % 600 )) -lt 30 ] && log "scene: waiting, $(others) other Factorio processes running"
      sleep 30
    done
    { echo "SCENE_OTHERS_AT_START=$(others)"; echo "SCENE_WAITED_S=$(( $(date +%s) - W0 ))"; } > "$RC_DIR/scene-load.env"
    manifest scene scene "$P-scene" ""
    log "start scene ($P-scene; $(others) other Factorio processes)"
    env KEEP_TREE="$T" SEED=701 $SCENE_ENV tools/perf-bench.sh scene "$P-scene" "$SCENE_MIN" > "$RC_DIR/scene.txt" 2>&1
    echo $? > "$RC_DIR/scene.rc"
    echo "SCENE_OTHERS_AT_END=$(others)" >> "$RC_DIR/scene-load.env"
    log "done scene"
  fi
fi

# --- GUI stages (Steam and the screen): only when asked for
if has lan || has heavy; then
  pgrep -x steam_osx >/dev/null || log "warning: Steam does not seem to run; the GUI clients will not start"
  log "GUI stages take the screen: no other GUI client may run"
  if has heavy; then manifest heavy heavy "$P-heavy" ""; log "start heavy"
    env KEEP_TREE="$T" tools/heavy-mode.sh "$P-heavy" "$([ -n "$QUICK" ] && echo 2 || echo 10)" > "$RC_DIR/heavy.txt" 2>&1
    echo $? > "$RC_DIR/heavy.rc"; fi
  if has lan; then manifest lan lan "$P-lan" ""; log "start lan"
    env KEEP_TREE="$T" tools/lan-check.sh "$P-lan" "$([ -n "$QUICK" ] && echo 3 || echo 10)" "$([ -n "$QUICK" ] && echo 1 || echo 5)" \
      > "$RC_DIR/lan.txt" 2>&1
    echo $? > "$RC_DIR/lan.rc"; fi
fi

echo "FINISHED=$(date '+%Y-%m-%d %H:%M')" >> "$RC_DIR/info-run.env"
python3 -I tools/release-check.py "$RC_DIR" > "$RC_DIR/REPORT.md" || { log "report failed"; exit 1; }
log "report: $RC_DIR/REPORT.md"
grep -E "^\*\*(PASS|FAIL|NOT JUDGED)\*\*" "$RC_DIR/REPORT.md" || true
