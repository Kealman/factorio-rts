#!/usr/bin/env bash
# Run several AI autotest samples in parallel (balance measurements): every config x REPS, at game speed SPEED
# (default 4: the game is deterministic per seed, so speed only changes the wall time; UPS numbers need speed 1).
# Rep r uses map seed SEED_BASE + r * 104729 (spread out: some generators ignore low seed bits): the same reps of two
# trees are paired samples.
# Usage: tools/autotest-batch.sh <tag> <reps> <config>...   config = 1v<n>-<easy|normal|hard>-<small|medium|large>
# KEEP_TREE=<dir> takes the mod from <dir>; CAP=<s> caps each run (default 400 s)
# Output: build/batch-<tag>/<config>-<rep>.txt; the server logs are build/bt-<tag>-<config>-<rep>-server.log
set -uo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?tag}"; REPS="${2:?reps}"; shift 2
# macOS ships bash 3.2 (no associative arrays)
cfg_of() {
  local opp=1 diff=normal size=small
  case "$1" in
    1v1-*) opp=1 ;; 1v2-*) opp=2 ;; 1v3-*) opp=3 ;; *) echo "unknown config $1" >&2; return 1 ;;
  esac
  case "$1" in *-easy-*) diff=easy ;; *-hard-*) diff=hard ;; esac
  case "$1" in *-medium) size=medium ;; *-large) size=large ;; esac
  printf '{opponents = %d, difficulty = "%s", size = "%s", enemy_brain = "ai"}' "$opp" "$diff" "$size"
}
OUT="build/batch-$TAG"; mkdir -p "$OUT"
for name in "$@"; do
  for r in $(seq 1 "$REPS"); do
    SEED=$(( ${SEED_BASE:-1000} + r * 104729 )) SPEED="${SPEED:-4}" tools/autotest-run.sh "bt-$TAG-$name-$r" "$(cfg_of "$name")" "${CAP:-400}" > "$OUT/$name-$r.txt" 2>&1 &
  done
done
wait
echo "batch $TAG done: $(ls "$OUT" | wc -l) runs"
