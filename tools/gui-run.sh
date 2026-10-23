#!/usr/bin/env bash
# Create a fresh save with the given mods dir and launch the real GUI client for up to CAP seconds
# (or until the log contains STOP_MARKER). Opens a window on this Mac; Steam must be running.
# Usage: tools/gui-run.sh <mods-dir> [cap-seconds=120] [stop-marker='SELFTEST done'] [grep-pattern='\[rts']
set -u
source "$(dirname "$0")/factorio-env.sh"
cd "$RTS_ROOT"
MODS_DIR="${1:?mods dir required}"; CAP="${2:-120}"; MARKER="${3:-SELFTEST done}"; PATTERN="${4:-\\[rts}"
factorio_version_guard "$MODS_DIR/factorio-rts" # the binary must match the tree's info.json factorio_version
RUN_ID="$(basename "$MODS_DIR")"
CFG="$(factorio_isolated_config "$RUN_ID-gui")"; SHOTS="$RTS_BUILD_DIR/runs/$RUN_ID-gui/script-output"
SAVE="$RTS_BUILD_DIR/$RUN_ID-gui.zip"; LOG="$RTS_BUILD_DIR/$RUN_ID-gui.log"
rm -f "$SAVE"
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$MODS_DIR" --create "$SAVE" > "$RTS_BUILD_DIR/$RUN_ID-gui-create.log" 2>&1 \
  || { echo "save creation failed, see $RTS_BUILD_DIR/$RUN_ID-gui-create.log"; exit 1; }
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$MODS_DIR" --load-game "$SAVE" --window-size 1280x800 --disable-audio > "$LOG" 2>&1 &
PID=$!
echo "started pid $PID at $(date +%T)"
for i in $(seq 1 "$CAP"); do
  sleep 1
  kill -0 "$PID" 2>/dev/null || { echo "client exited on its own after $i s"; break; }
  grep -q "$MARKER" "$LOG" && { echo "marker '$MARKER' seen after $i s"; sleep 3; break; }
done
kill "$PID" 2>/dev/null; sleep 3; kill -9 "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
ls "$SHOTS"/*.png >/dev/null 2>&1 && { mkdir -p "$RTS_BUILD_DIR/shots-$RUN_ID"; mv "$SHOTS"/*.png "$RTS_BUILD_DIR/shots-$RUN_ID/"; echo "screenshots moved to $RTS_BUILD_DIR/shots-$RUN_ID/"; }
echo "stopped at $(date +%T); log: $LOG"
grep -E "$PATTERN" "$LOG" | grep -v STATUS | tail -60
