#!/usr/bin/env bash
# Phase 4 validation matrix: every scenario below runs in parallel through tools/autotest-run.sh (8-minute AI
# autotests at game speed 1, so the perf lines measure real UPS) plus the legacy Phase 1/2 unit autotest; the -nosa
# scenarios run with Space Age, quality and elevated rails disabled. -stress adds 105 units per force at 60 s and logs
# per-module handler times; -restart restarts the match at 4 minutes and runs the AI autotest again (speed 3).
# Usage: tools/autotest-matrix.sh <tag> [scenario-name-filter]
# Env: JOBS=<n> runs at most n scenarios at a time (default: all ten at once); SEED, KEEP_TREE pass through.
# Output: build/matrix-<tag>/<scenario>.txt and a one-line-per-run table at the end.
set -uo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?tag}"; FILTER="${2:-}"
OUT="build/matrix-$TAG"; mkdir -p "$OUT"
SCENARIOS=(
  "1v1-normal-medium|{opponents = 1, difficulty = \"normal\", size = \"medium\", enemy_brain = \"ai\"}|640"
  "1v2-normal-medium|{opponents = 2, difficulty = \"normal\", size = \"medium\", enemy_brain = \"ai\"}|640"
  "1v3-normal-small|{opponents = 3, difficulty = \"normal\", size = \"small\", enemy_brain = \"ai\"}|640"
  "1v1-hard-medium|{opponents = 1, difficulty = \"hard\", size = \"medium\", enemy_brain = \"ai\"}|640"
  "1v1-easy-medium|{opponents = 1, difficulty = \"easy\", size = \"medium\", enemy_brain = \"ai\"}|640"
  "legacy-units|{opponents = 1, difficulty = \"normal\", size = \"small\", enemy_brain = \"waves\"}|330"
  "1v1-normal-small-nosa|{opponents = 1, difficulty = \"normal\", size = \"small\", enemy_brain = \"ai\"}|640|base"
  "legacy-units-nosa|{opponents = 1, difficulty = \"normal\", size = \"small\", enemy_brain = \"waves\"}|330|base"
  "1v3-normal-small-stress|{opponents = 3, difficulty = \"normal\", size = \"small\", enemy_brain = \"ai\"}|640|sa|STRESS=60:70 PERF=1"
  "1v1-normal-small-restart|{opponents = 1, difficulty = \"normal\", size = \"small\", enemy_brain = \"ai\"}|900|sa|RESTART_AT=240 SPEED=3"
)
for s in "${SCENARIOS[@]}"; do
  IFS='|' read -r name match cap variant extra <<< "$s"
  [ -n "$FILTER" ] && [[ "$name" != *$FILTER* ]] && continue
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "${JOBS:-99}" ]; do sleep 5; done
  env VARIANT="${variant:-sa}" ${extra:-} tools/autotest-run.sh "mx-$TAG-$name" "$match" "$cap" > "$OUT/$name.txt" 2>&1 &
done
wait
echo "=== matrix $TAG ==="
for f in "$OUT"/*.txt; do
  name="$(basename "$f" .txt)"
  summary="$(grep -E "autotest summary" "$f" | tail -1 | sed -E 's/.*(autotest summary)/\1/')"
  errs="$(sed -n '/=== errors ===/,/^log:/p' "$f" | grep -vcE '^(=== errors ===|log:|\(none\))')"
  echo "$name | errors $errs | ${summary:-no summary}"
done
