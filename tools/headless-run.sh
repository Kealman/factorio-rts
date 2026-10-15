#!/usr/bin/env bash
# Create a fresh map with our mods and run a headless server for N seconds, then print mod log lines.
# Usage: tools/headless-run.sh [seconds=20] [grep-pattern='\[rts'] [mods-dir=$RTS_MODS_DIR]  (each spike has its own mods dir)
# Verified on Factorio 2.0.77 mac-arm64 (2026-10-15): --create and --start-server run without a window.
set -euo pipefail
source "$(dirname "$0")/factorio-env.sh"
SECS="${1:-20}"
PATTERN="${2:-\\[rts}"
MODS_DIR="${3:-$RTS_MODS_DIR}"
RUN_ID="$(basename "$MODS_DIR")"
SAVE="$RTS_BUILD_DIR/$RUN_ID-headless.zip"
LOG="$RTS_BUILD_DIR/$RUN_ID-server.log"
rm -f "$SAVE"
"$FACTORIO_BIN" --mod-directory "$MODS_DIR" --create "$SAVE" > "$RTS_BUILD_DIR/$RUN_ID-create.log" 2>&1 \
  || { echo "map creation failed:"; grep -iE "error" "$RTS_BUILD_DIR/$RUN_ID-create.log" | head -20; exit 1; }
"$FACTORIO_BIN" --mod-directory "$MODS_DIR" --start-server "$SAVE" \
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
