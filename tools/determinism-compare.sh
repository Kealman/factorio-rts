#!/usr/bin/env bash
# Phase 5 M3 perf: two runs of the same match and seed, compared line by line (docs/PHASE5-M3.md section 4 "Perf /
# determinism"; docs/qa/phase5-perf-notes.md). Each run is a fresh --create with the seed and a --benchmark of the given
# minutes through tools/perf-bench.sh (match mode: as fast as the machine goes; the headless autotest starts the match
# at tick 120 exactly as on a server), with PERF and the tick marks off, so nothing but the game itself is in the logs.
#
# Usage: tools/determinism-compare.sh <name> '<lua match table>' <minutes> [seed=701]
#   tools/determinism-compare.sh det-701 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
#       enemy_brain = "ai"}' 30 701
# Env: KEEP_TREE=<dir> the tree of run A (default mods/factorio-rts); TREE_B=<dir> the tree of run B (default: A's): two
#      trees compare a change against its base (Skirmish must stay line-identical: WHAT=all);
#      WHAT=events (default) | all
#        events: city sites and foundings, captures, wars, ceasefires, peaces and treaties, the AI's planned start lines
#                and second cities, rail lines and surveys, ports taken (the M3 determinism criterion)
#        all:    every "[rts]" line, timing-only lines dropped and run-time durations normalised (as tools/matrix-compare.sh)
#      MAXD=<n> differing lines shown (default 12); VARIANT=sa|base; EXTRA_A / EXTRA_B=<file> a test module for one side
#      (tools/probes/perf_noslice.lua: the M3 tree with the unsliced Nation AI, to check that the M3 hunks change nothing
#      else); PARALLEL=1 runs both sides at once (half the wall clock; on a busy machine both see the same load).
# Output: one row per run with its line count, the number of differing lines and the first differences; exit 1 when the
# runs differ. Logs: build/<name>-a-out/bench.log, build/<name>-b-out/bench.log.
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
NAME="${1:?name}"; MATCH="${2:?lua match table}"; MIN="${3:?minutes}"; SEED="${4:-701}"
WHAT="${WHAT:-events}"; MAXD="${MAXD:-12}"
TREE_A="${KEEP_TREE:-$RTS_MODS_DIR/factorio-rts}"; TREE_B="${TREE_B:-$TREE_A}"
run_side() { # <a|b> <tree> <extra lua>
  echo "run $1: $2${3:+ + $(basename "$3")}, seed $SEED, $MIN minutes ..."
  KEEP_TREE="$2" SEED="$SEED" PERF=0 MARKS=0 EXTRA_LUA="$3" "$RTS_ROOT/tools/perf-bench.sh" match "$NAME-$1" "$MATCH" \
    "$MIN" > "$RTS_BUILD_DIR/$NAME-$1.txt" 2>&1
  grep -A3 "=== errors ===" "$RTS_BUILD_DIR/$NAME-$1.txt" | grep -E "Error|rror while|Exception" | head -3
}
if [ -n "${PARALLEL:-}" ]; then
  run_side a "$TREE_A" "${EXTRA_A:-}" & run_side b "$TREE_B" "${EXTRA_B:-}" & wait
else
  run_side a "$TREE_A" "${EXTRA_A:-}"
  run_side b "$TREE_B" "${EXTRA_B:-}"
fi
python3 - "$RTS_BUILD_DIR/$NAME-a-out/bench.log" "$RTS_BUILD_DIR/$NAME-b-out/bench.log" "$WHAT" "$MAXD" <<'PY'
import re, sys, difflib
pa, pb, mode, maxd = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
PREFIX = re.compile(r"^ *[0-9.]+ Script @__factorio-rts__/[^ ]+ ")
TIMING = re.compile(r"perf|wall clock| ms\b|ms/tick|ms per|took [0-9.]+ ?ms|elapsed|real time|UPS|Duration", re.I)
NORMALISE = [(re.compile(r"Duration: [0-9.]+ ?[a-z]*"), "Duration: T")]
EVENTS = re.compile(r"second city planned|city site|city \d+ of \S+ registered|cities: city \d+ .*(lost|captured|changes)"
                    r"|founded|declares war|-> (war|peace|ceasefire)|ceasefire|treaty|peace (signed|treaty)|captured by"
                    r"|capture: .*(captured|flip|taken)|start lines planned|rails: line #\d+ of|survey #\d+ (done|failed)"
                    r"|world: planned|town .*planned|hub \d+ planned", re.I)
def lines(path):
    out = []
    for line in open(path, errors="replace"):
        if "[rts]" not in line: continue
        line = PREFIX.sub("", line.rstrip("\n"))
        line = re.sub(r"^ *[0-9.]+ ", "", line)
        if mode == "events":
            if not EVENTS.search(line): continue
            line = re.sub(r" in Duration: [0-9.]+ ?[a-z]*", "", line)
            line = re.sub(r"Duration: [0-9.]+ ?[a-z]*", "Duration: T", line)
        else:
            for rx, rep in NORMALISE: line = rx.sub(rep, line)
            if TIMING.search(line): continue
        out.append(line)
    return out
a, b = lines(pa), lines(pb)
diff = [d for d in difflib.unified_diff(a, b, "a", "b", lineterm="", n=0) if not d.startswith(("---", "+++", "@@"))]
print(f"=== {mode} lines: run a {len(a)}, run b {len(b)}, differing {len(diff)} ===")
for d in diff[:maxd]: print("  " + d[:220])
if mode == "events":
    kinds = {}
    for l in a:
        k = ("city" if re.search(r"city|founded", l) else "war" if re.search(r"war|peace|ceasefire|treaty", l)
             else "rails" if "rails:" in l else "other")
        kinds[k] = kinds.get(k, 0) + 1
    print("  event lines of run a by kind: " + ", ".join(f"{k} {v}" for k, v in sorted(kinds.items())))
sys.exit(1 if diff else 0)
PY
