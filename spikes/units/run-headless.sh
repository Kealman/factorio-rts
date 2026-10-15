#!/usr/bin/env bash
# Same as tools/headless-run.sh, but with an isolated write-data directory (own .lock, config, saves)
# and its own UDP port, so it can run while other spikes' servers are running.
# Usage: spikes/units/run-headless.sh [seconds=100] [grep-pattern='\[rts-units'] [mods-dir=spikes/units] [port=34211]
set -euo pipefail
source "$(dirname "$0")/../../tools/factorio-env.sh"
SECS="${1:-100}"
PATTERN="${2:-\\[rts-units}"
MODS_DIR="$(cd "${3:-$RTS_ROOT/spikes/units}" && pwd)"
PORT="${4:-34211}"
RUN_ID="$(basename "$MODS_DIR")"
WRITE_DIR="$RTS_BUILD_DIR/$RUN_ID-write"
mkdir -p "$WRITE_DIR/config"
CONFIG="$WRITE_DIR/config/config.ini"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$WRITE_DIR" > "$CONFIG"
SAVE="$RTS_BUILD_DIR/$RUN_ID-headless.zip"
LOG="$RTS_BUILD_DIR/$RUN_ID-server.log"
rm -f "$SAVE"
"$FACTORIO_BIN" --config "$CONFIG" --mod-directory "$MODS_DIR" --create "$SAVE" > "$RTS_BUILD_DIR/$RUN_ID-create.log" 2>&1 \
  || { echo "map creation failed:"; grep -iE "error" "$RTS_BUILD_DIR/$RUN_ID-create.log" | head -20; exit 1; }
"$FACTORIO_BIN" --config "$CONFIG" --mod-directory "$MODS_DIR" --port "$PORT" --start-server "$SAVE" \
  --server-settings "$RTS_ROOT/tools/server-settings.json" > "$LOG" 2>&1 &
PID=$!
sleep "$SECS"
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
echo "=== mod log lines matching /$PATTERN/ ==="
grep -E "$PATTERN" "$LOG" || true
echo "=== errors ==="
grep -E "Error|rror while running|Exception" "$LOG" | grep -v "Got EOF on stdin" || echo "(none)"
echo "full log: $LOG"
