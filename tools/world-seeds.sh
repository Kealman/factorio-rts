#!/usr/bin/env bash
# Phase 5 M1 world seed matrix (docs/PHASE5-M1.md §4 World): tools/probes/world_seeds.lua in a headless test copy.
# Usage: tools/world-seeds.sh <name> [seeds=20] [nations='2, 3, 4'] [world_size=nil] [cap=3600]
#   KEEP_TREE=<dir> as for tools/autotest-run.sh; IMAGES=1 writes rts-world-*.ppm (script-output of the run).
# Prints the per-run lines and a table with the time checks: start (plan + blocking core + start kits) <= 15 s.
set -uo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?name}"; SEEDS="${2:-20}"; NATIONS="${3:-2, 3, 4}"; SIZE="${4:-nil}"; CAP="${5:-3600}"
TMP="build/$NAME-probe"; mkdir -p "$TMP"
sed -E "s/^local CFG = \{.*\}( --.*)?$/local CFG = {seeds = $SEEDS, nations = {$NATIONS}, world_size = $SIZE, images = $([ -n "${IMAGES:-}" ] && echo true || echo false)}/" \
  tools/probes/world_seeds.lua > "$TMP/world_seeds.lua"
grep -q "^local CFG = {seeds = $SEEDS" "$TMP/world_seeds.lua" || { echo "CFG line not rewritten"; exit 1; }
EXTRA_LUA="$TMP/world_seeds.lua" tools/autotest-run.sh "$NAME" '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' "$CAP" > "build/$NAME.txt" 2>&1
LOG="build/$NAME-server.log"
grep -E "world seeds:|autotest check|autotest summary" "$LOG" | sed -E 's/^ *[0-9.]+ Script @__factorio-rts__\/[^ ]+ //' | cut -c1-400
sed -n '/=== errors ===/,$p' "build/$NAME.txt"
python3 - "$LOG" <<'PY'
import re, sys
starts, fills = [], []
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"world seeds: run (\d+) nations (\d+) seed (\d+) size (\d+): start .*Duration: ([0-9.]+)ms", line)
    if m: starts.append((int(m[1]), int(m[2]), int(m[3]), int(m[4]), float(m[5])))
    m = re.search(r"world seeds: run (\d+) nations (\d+) seed (\d+): forced fill .*Duration: ([0-9.]+)ms", line)
    if m: fills.append(float(m[4]))
bad = [s for s in starts if s[4] > 15000]
by = {}
for s in starts: by.setdefault((s[1], s[3]), []).append(s[4])
print("=== start time (plan + blocking core + start kits), ms ===")
for (n, size), v in sorted(by.items()):
    v = sorted(v)
    print(f"nations {n} size {size}: runs {len(v)}, min {v[0]:.0f}, median {v[len(v)//2]:.0f}, max {v[-1]:.0f}")
if fills:
    f = sorted(fills)
    print(f"forced fill of the rest: runs {len(f)}, min {f[0]:.0f}, median {f[len(f)//2]:.0f}, max {f[-1]:.0f} ms")
print(f"world_generation_15s: {'PASS' if starts and not bad else 'FAIL'} ({len(starts) - len(bad)}/{len(starts)} starts within 15 s)")
PY
