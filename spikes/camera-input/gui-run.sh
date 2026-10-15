#!/usr/bin/env bash
# Automated GUI run of the camera spike: fresh save, launch the client, wait for the self-tests
# (or the cap), stop the client, copy screenshots to build/.
# Usage: spikes/camera-input/gui-run.sh [cap-seconds=130]
# Opens a real game window for about 85 s. Steam must be running.
set -u
source "$(dirname "$0")/../../tools/factorio-env.sh"
cd "$RTS_ROOT"
CAP="${1:-130}"
SAVE=build/camera-spike.zip
LOG=build/camera-gui.log
SHOTS="$HOME/Library/Application Support/factorio/script-output"
rm -f "$SAVE"
"$FACTORIO_BIN" --mod-directory spikes/camera-input --create "$SAVE" > build/camera-spike-create.log 2>&1 \
  || { echo "save creation failed, see build/camera-spike-create.log"; exit 1; }
# Without SteamAppId the Steam build prints "Steam requires game restart, restarting..." and exits,
# and Steam does not relaunch it with our arguments.
SteamAppId=427520 SteamGameId=427520 "$FACTORIO_BIN" --mod-directory spikes/camera-input --load-game "$SAVE" \
  --window-size 1280x800 --disable-audio > "$LOG" 2>&1 &
PID=$!
echo "started pid $PID at $(date +%T)"
for i in $(seq 1 "$CAP"); do
  sleep 1
  if ! kill -0 "$PID" 2>/dev/null; then echo "client exited on its own after $i s"; break; fi
  if grep -q "SELFTEST done" "$LOG"; then echo "self-tests done after $i s"; sleep 3; break; fi
done
kill "$PID" 2>/dev/null; sleep 3; kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
cp "$SHOTS"/rts-camera-*.png build/ 2>/dev/null && echo "screenshots copied to build/"
echo "stopped at $(date +%T)"
grep "\[rts-camera\]" "$LOG" | grep -v STATUS | sed 's/Script @__rts-spike-camera__\/control.lua:31: //'
