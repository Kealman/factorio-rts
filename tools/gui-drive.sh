#!/usr/bin/env bash
# Real input for a GUI probe (Phase 5 M2 QA round 1): runs every "RTS_DRIVE <n> <cmd> <args>" line of a GUI log once,
# in order. Commands: click X Y, rclick X Y, move X Y, key <keycode> (tools/gui-input/fdrive.swift, game-area
# coordinates of the 1280x800 window) and capture <tag> (a window capture into OUT/<tag>.png; take_screenshot cannot
# show the engine's own info boxes). Ends at MARKER or when the client is gone. Start it before tools/gui-run.sh:
#   tools/gui-drive.sh build/<run>-gui.log build/shots-<run>-window RTS_QF_DONE & tools/gui-run.sh build/<run> 600 RTS_QF_DONE
# The input reaches whatever Factorio window is in front: check `pgrep -fl 'MacOS/factorio' | grep window-size` first.
set -u
source "$(dirname "$0")/factorio-env.sh"
LOG="${1:?gui log}"; OUT="${2:?capture dir}"; MARKER="${3:-RTS_QF_DONE}"
BIN="$RTS_BUILD_DIR/fdrive"
if [ ! -x "$BIN" ] || [ "$RTS_ROOT/tools/gui-input/fdrive.swift" -nt "$BIN" ]; then
  swiftc -O -o "$BIN" "$RTS_ROOT/tools/gui-input/fdrive.swift" || { echo "gui-drive: swiftc failed"; exit 1; }
fi
mkdir -p "$OUT"
last=0
front() {
  local pid; pid=$(pgrep -f 'MacOS/factorio.*window-size' | head -1)
  [ -n "$pid" ] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1
}
for i in $(seq 1 18000); do
  sleep 0.2
  [ -f "$LOG" ] || continue
  while IFS= read -r line; do
    set -- $line
    n="$2"; cmd="$3"; a="${4:-}"; b="${5:-}"
    [ "$n" -le "$last" ] && continue
    last=$n
    case "$cmd" in
      capture) wid=$("$BIN" win | awk '{print $1}'); screencapture -x -o -l "$wid" "$OUT/$a.png"; echo "captured $a";;
      click|rclick|move) front; "$BIN" "$cmd" "$a" "$b"; echo "$cmd $a $b";;
      key) front; "$BIN" key "$a"; echo "key $a";;
    esac
  done < <(grep -o 'RTS_DRIVE [0-9]* .*' "$LOG")
  grep -q "$MARKER" "$LOG" && { echo "gui-drive: marker seen"; break; }
  [ "$i" -gt 150 ] && ! pgrep -f 'MacOS/factorio.*window-size' >/dev/null && { echo "gui-drive: client gone"; break; }
done
