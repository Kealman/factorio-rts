#!/usr/bin/env bash
# Phase 5 M3 world3 (docs/PHASE5-M3.md §4 "World 3"): tools/probes/world3_autotest.lua in a headless Nation match with
# the AIs playing, the world filling in the background.
# Usage: tools/world3-run.sh <name> <nations 2-6> <world_size 2048|3072|4096> [save_at_s] [cap_s=1500]
#   KEEP_TREE, SEED, PERF, SPEED pass through to tools/autotest-run.sh; SURVEY=1 starts the match with the Survey map
#   (config.survey: the generated world is charted for the charted forces; a headless server charts nothing, so only
#   the chart calls and their log line are exercised).
#   save_at_s: the probe logs "world3: save point" at that match time; the server stops there (a headless server saves
#   when it quits), a second server loads the save and runs on to the probe's summary.
# Prints the checks, the core and start times (contract: core <= 3 s at 4096), the fill rate and the UPS while the
# world filled (wall time of the progress lines against their game time).
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
NAME="${1:?name}"; NATIONS="${2:?nations}"; SIZE="${3:?world size}"; SAVE_AT="${4:-}"; CAP="${5:-1500}"
factorio_version_guard "${KEEP_TREE:-$RTS_MODS_DIR/factorio-rts}" # the binary must match the tree's info.json
TMP="$RTS_BUILD_DIR/$NAME-probe"; mkdir -p "$TMP"
SAVE_LUA="nil"; [ -n "$SAVE_AT" ] && SAVE_LUA="$SAVE_AT"
sed -E "s/^local CFG = \{.*\}( --.*)?$/local CFG = {save_at = $SAVE_LUA, fill_limit_s = 480, area_chunks = 3}/" \
  "$RTS_ROOT/tools/probes/world3_autotest.lua" > "$TMP/world3_autotest.lua"
grep -q "^local CFG = {save_at = $SAVE_LUA" "$TMP/world3_autotest.lua" || { echo "CFG line not rewritten"; exit 1; }
MATCH="{opponents = $(( NATIONS - 1 )), difficulty = \"normal\", mode = \"nation\", world_size = $SIZE, enemy_brain = \"ai\"${SURVEY:+, survey = true}}"
STOP='\[rts\] world3 autotest summary'
[ -n "$SAVE_AT" ] && STOP='\[rts\] world3: save point|\[rts\] world3 autotest summary'
EXTRA_LUA="$TMP/world3_autotest.lua" DURATION_MIN="${DURATION_MIN:-40}" STOP_ON="$STOP" \
  "$RTS_ROOT/tools/autotest-run.sh" "$NAME" "$MATCH" "$CAP" > "$RTS_BUILD_DIR/$NAME.txt" 2>&1
LOG="$RTS_BUILD_DIR/$NAME-server.log"
LOGS=("$LOG")
if [ -n "$SAVE_AT" ] && grep -q "world3: save point" "$LOG"; then
  SAVE="$RTS_BUILD_DIR/$NAME-headless.zip"
  grep -q "Saving map as $SAVE" "$LOG" || { echo "the server did not save $SAVE on quit"; exit 1; }
  echo "=== loading $SAVE ==="
  CFGINI="$(factorio_isolated_config "$NAME")"
  PORT=$(( 38000 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 1000 ) ))
  while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
  LOG2="$RTS_BUILD_DIR/$NAME-loaded-server.log"
  "$FACTORIO_BIN" -c "$CFGINI" --mod-directory "$RTS_BUILD_DIR/$NAME" --start-server "$SAVE" --port "$PORT" \
    --server-settings "$RTS_ROOT/tools/server-settings.json" > "$LOG2" 2>&1 &
  PID=$!
  START=$(date +%s)
  while kill -0 "$PID" 2>/dev/null; do
    sleep 2
    grep -q "world3 autotest summary" "$LOG2" && { sleep 2; break; }
    [ $(( $(date +%s) - START )) -ge "$CAP" ] && break
  done
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  LOGS+=("$LOG2")
fi
for L in "${LOGS[@]}"; do
  echo "=== $(basename "$L") ==="
  grep -E "world: .*generated: core|world: planned|world3:|w3_|world3 autotest summary|world: background generation done|world: real-tile|world: no chunk|world: request order|world: rts-ai|world: survey" "$L" \
    | sed -E 's/^ *[0-9.]+ Script @__factorio-rts__\/[^ ]+ //' | cut -c1-420
  echo "--- errors"
  grep -nE "Error|rror while running|Exception|Unknown key|missing locale" "$L" | grep -v "Got EOF on stdin" | head -10 || true
done
python3 - "${LOGS[@]}" <<'PY'
import re, sys
for path in sys.argv[1:]:
    prog = []
    for line in open(path, errors="replace"):
        m = re.match(r"\s*([0-9.]+) .*world3: progress t=(\d+) s generated (\d+)/(\d+)", line)
        if m: prog.append((float(m[1]), int(m[2]), int(m[3]), int(m[4])))
        m = re.search(r"generated: core (\d+) chunks .*core in Duration: ([0-9.]+)ms; start in Duration: ([0-9.]+)ms", line)
        if m: print(f"{path.split('/')[-1]}: core {m[1]} chunks in {float(m[2])/1000:.2f} s (worldgen.start {float(m[3])/1000:.2f} s)")
        m = re.search(r"world: planned .* planned in Duration: ([0-9.]+)ms", line)
        if m: print(f"{path.split('/')[-1]}: planning {float(m[1])/1000:.2f} s")
    if len(prog) >= 2:
        (w0, t0, g0, n), (w1, t1, g1, _) = prog[0], prog[-1]
        if w1 > w0 and t1 > t0:
            print(f"{path.split('/')[-1]}: progress {t0}-{t1} s of game time in {w1 - w0:.1f} s of wall time: "
                  f"{(t1 - t0) / (w1 - w0) * 60:.1f} UPS; {g0}->{g1} of {n} chunks, {(g1 - g0) / (t1 - t0):.1f} chunks per game s")
PY
