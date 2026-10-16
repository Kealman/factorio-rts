#!/usr/bin/env bash
# Headless autotest scenario: copies mods/factorio-rts to build/<name>/, points the copy's autotest at one match
# config, runs a headless server until the autotest summary line (or CAP seconds) and prints the summary, the minute
# and perf lines and every Lua error. Parallel runs are fine (own config dir and port per name).
#
# Usage: tools/autotest-run.sh <name> '<lua match table>' [cap-seconds=640]
#   tools/autotest-run.sh m-1v1-normal-medium '{opponents = 1, difficulty = "normal", size = "medium", enemy_brain = "ai"}'
#   tools/autotest-run.sh m-legacy '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 300
# Env:
#   VARIANT=sa|base     Space Age on (default) or base game only (mod-list.json of the copy)
#   SPEED=1             game.speed of the copy (UPS numbers are only meaningful at 1)
#   DURATION_MIN=8      AI autotest length in minutes
#   DOCTRINES='{...}'   Lua table for ai/autotest.lua DOCTRINES (nil = the seeded draw for every force)
#   RESTART_AT=<s>      debug.lua: restart the match through the Ctrl+Shift+R path this many seconds into the AI
#                       autotest, then run the autotest again on the new match
#   PERF=1              per-module handler profiling (scripts/events.lua) logged every minute
#   STRESS=<s>:<n>      load test: <s> seconds after the match start every match force gets <n> extra walkers and
#                       <n>/2 drones (/rts-spawn, at most 100 per call), which its AI commander takes into its army
#   STOP_ON=<regex>     stop marker (default: the autotest summary line)
#   KEEP_TREE=<dir>     take the mod from this directory instead of mods/factorio-rts
#   EXTRA_LUA=<file>    a test-only module (tools/probes/*.lua): copied into the copy's scripts/ and required last
#   SEED=<n>            map seed (--map-gen-seed); without it --create draws a seed from the clock, so runs started in
#                       the same second share a seed and are identical (the arena, doctrines and AI timings follow it)
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
NAME="${1:?name}"; MATCH="${2:?lua match table}"; CAP="${3:-640}"
VARIANT="${VARIANT:-sa}"; SPEED="${SPEED:-1}"
STOP_ON="${STOP_ON:-\[rts\] (ai )?autotest summary}"
SRC="${KEEP_TREE:-$RTS_MODS_DIR/factorio-rts}"
DIR="$RTS_BUILD_DIR/$NAME"
rm -rf "$DIR"; mkdir -p "$DIR"
cp -R "$SRC" "$DIR/factorio-rts"
M="$DIR/factorio-rts"
# the match the autotest starts (debug.lua AUTOTEST_MATCH)
python3 - "$M/scripts/debug.lua" "$MATCH" <<'PY'
import re, sys
path, table = sys.argv[1], sys.argv[2]
src = open(path).read()
new, n = re.subn(r'^local AUTOTEST_MATCH = \{.*\}$', 'local AUTOTEST_MATCH = ' + table, src, count=1, flags=re.M)
assert n == 1, "AUTOTEST_MATCH line not found"
open(path, "w").write(new)
PY
if [ -n "${DURATION_MIN:-}" ]; then
  sed -i '' "s|^autotest.DURATION = .*|autotest.DURATION = ${DURATION_MIN} * 60 * 60|" "$M/scripts/ai/autotest.lua"
fi
if [ -n "${DOCTRINES:-}" ]; then
  sed -i '' "s|^autotest.DOCTRINES = .*|autotest.DOCTRINES = ${DOCTRINES}|" "$M/scripts/ai/autotest.lua"
fi
{
  printf '\n-- test copy (tools/autotest-run.sh)\n'
  [ "$SPEED" != "1" ] && printf 'require("scripts.events").on_init(function() game.speed = %s end)\n' "$SPEED"
  [ -n "${RESTART_AT:-}" ] && printf 'require("scripts.debug").AUTOTEST_RESTART_AT = %s\n' "$RESTART_AT"
  [ -n "${PERF:-}" ] && printf 'require("scripts.events").enable_profiling()\n'
  if [ -n "${EXTRA_LUA:-}" ]; then
    cp "$EXTRA_LUA" "$M/scripts/$(basename "$EXTRA_LUA")"
    printf 'require("scripts.%s")\n' "$(basename "$EXTRA_LUA" .lua)"
  fi
  if [ -n "${STRESS:-}" ]; then
    printf 'do\n  local at, n = %s, %s\n' "${STRESS%%:*}" "${STRESS##*:}"
    cat <<'LUA'
  local events, dbg, match = require("scripts.events"), require("scripts.debug"), require("scripts.match")
  events.on_nth_tick(60, function()
    local m = storage.match
    if storage.stress_done or not (m and m.phase == "running" and m.tick_started) then return end
    if game.tick - m.tick_started < at * 60 then return end
    storage.stress_done = true
    for _, f in ipairs(match.forces()) do
      for _, spec in ipairs({{"rts-walker", n}, {"rts-drone", math.floor(n / 2)}}) do
        local left = spec[2]
        while left > 0 do
          dbg.run_command("rts-spawn", string.format("%s %d %s", spec[1], math.min(100, left), f))
          left = left - 100
        end
      end
    end
    log("[rts] stress: spawned at tick " .. game.tick)
  end)
end
LUA
  fi
} >> "$M/control.lua"
if [ "$VARIANT" = "base" ]; then
  printf '{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":false},{"name":"quality","enabled":false},{"name":"space-age","enabled":false},{"name":"factorio-rts","enabled":true}]}\n' > "$DIR/mod-list.json"
else
  cp "$RTS_MODS_DIR/mod-list.json" "$DIR/"
fi
CFG="$(factorio_isolated_config "$NAME")"
# per-run UDP port: a hash of the name, moved on while another server holds it (parallel batches)
PORT=$(( 35000 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 3000 ) ))
while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
SAVE="$RTS_BUILD_DIR/$NAME-headless.zip"; LOG="$RTS_BUILD_DIR/$NAME-server.log"; CREATE="$RTS_BUILD_DIR/$NAME-create.log"
rm -f "$SAVE" "$LOG"
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --create "$SAVE" ${SEED:+--map-gen-seed "$SEED"} > "$CREATE" 2>&1 \
  || { echo "map creation failed:"; grep -iE "error" "$CREATE" | head -20; exit 1; }
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --start-server "$SAVE" --port "$PORT" \
  --server-settings "$RTS_ROOT/tools/server-settings.json" > "$LOG" 2>&1 &
PID=$!
START=$(date +%s)
STATUS="cap ${CAP}s reached"
while true; do
  sleep 2
  kill -0 "$PID" 2>/dev/null || { STATUS="server exited"; break; }
  grep -qE "$STOP_ON" "$LOG" && { sleep 2; STATUS="stop marker after $(( $(date +%s) - START ))s"; break; }
  [ $(( $(date +%s) - START )) -ge "$CAP" ] && break
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo "=== $NAME: $STATUS (variant $VARIANT, speed $SPEED) ==="
grep -E "\[rts\] (ai autotest (check|summary)|autotest (check .*FAIL|summary)|ai minute [0-9]+ (rts|match)|ai perf minute [0-9]+: AI time per tick|perf |restart|field probe)" "$LOG" \
  | sed -E 's/^ *[0-9.]+ Script @__factorio-rts__\/[^ ]+ //' || true
echo "=== errors ==="
grep -nE "Error|rror while running|Exception|Unknown key|missing locale" "$LOG" "$CREATE" | grep -v "Got EOF on stdin" | head -20 \
  || echo "(none)"
echo "log: $LOG"
