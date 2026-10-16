#!/usr/bin/env bash
# Save/load check: runs an AI autotest match headless until minute 3 of the AI autotest and stops the server (a headless
# server saves the map when it quits), then starts a new server from that save and lets it run on. A module that keeps
# state outside storage, writes storage in on_load or stores something unsaveable shows up as a load error or as a Lua
# error after the load. Prints the errors of both halves and the minute reports logged after the load.
# Usage: tools/saveload-check.sh <name> '<lua match table>' [seconds-after-load=150]
# Env: SAVE_MINUTE=3 (the AI autotest minute the save is taken at; pass SPEED, DURATION_MIN, SEED, EXTRA_LUA through to
#      tools/autotest-run.sh for a later save, e.g. a Nation match with a town and a train: SAVE_MINUTE=30 SPEED=6)
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
NAME="${1:?name}"; MATCH="${2:?lua match table}"; AFTER="${3:-150}"
SAVE_MINUTE="${SAVE_MINUTE:-3}"
STOP_ON="\[rts\] ai minute $SAVE_MINUTE match" "$RTS_ROOT/tools/autotest-run.sh" "$NAME" "$MATCH" \
  $(( 400 + SAVE_MINUTE * 70 )) | sed -n '/=== errors ===/,$p'
SAVE="$RTS_BUILD_DIR/$NAME-headless.zip"
grep -q "Saving map as $SAVE" "$RTS_BUILD_DIR/$NAME-server.log" || { echo "the server did not save $SAVE on quit"; exit 1; }
echo "=== loading $SAVE ==="
CFG="$(factorio_isolated_config "$NAME")"
PORT=$(( 38000 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 1000 ) ))
while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
LOG="$RTS_BUILD_DIR/$NAME-loaded-server.log"
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$RTS_BUILD_DIR/$NAME" --start-server "$SAVE" --port "$PORT" \
  --server-settings "$RTS_ROOT/tools/server-settings.json" > "$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 "$AFTER"); do sleep 1; kill -0 "$PID" 2>/dev/null || break; done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo "=== after the load: $(grep -c '\[rts\]' "$LOG") [rts] lines; minute reports: ==="
grep -E "\[rts\] ai (minute [0-9]+ (match|rts-player:)|perf minute [0-9]+: [0-9]+ AI runs)" "$LOG" \
  | sed -E 's/^ *[0-9.]+ Script @[^ ]+ //' | cut -c1-170
echo "=== errors after the load ==="
grep -nE "Error|rror while running|Exception" "$LOG" | grep -v "Got EOF on stdin" | head -20 || echo "(none)"
echo "log: $LOG"
