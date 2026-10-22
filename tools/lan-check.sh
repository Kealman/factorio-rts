#!/usr/bin/env bash
# Phase 5 M3 perf: a two-client LAN session (docs/PHASE5-M3.md D9 and section 4 "Perf / determinism";
# docs/qa/phase5-perf-notes.md). A headless server plays a 4-nation normal AI match (the headless autotest starts it at
# tick 120 because nobody is connected yet), a GUI client joins with --mp-connect once the match runs, a second GUI
# client joins JOIN2 minutes later, both stay MINUTES minutes. tools/probes/perf_lan.lua logs an order-independent state
# checksum on every peer every 10 s ("[rts] lan check t<tick>: ..."). Result:
#   - "desync" (any case) in the server log or a client log, or a desync report folder in a client's write-data: FAIL;
#   - every "lan check" line a client logged must equal the server's line of the same tick: FAIL on any mismatch;
#   - both clients must have joined ("lan check: player rts-lan-N joined" in the server log), Lua errors are listed.
# The GUI clients open windows on this Mac (Steam must run). Both clients run under the one Steam account of this Mac,
# whose player name comes from Steam Cloud's player-data.json (a local player-data.json is not read; it was empty here),
# so the server refuses the second one while the first is connected ("UserWithThatNameAlreadyInGame"). The script then
# hands over: client 1 quits and client 2 joins the running match in its place (a mid-match join with a fresh client);
# the log says which way client 2 joined. Two concurrent clients need a second account (or a second machine).
#
# Usage: tools/lan-check.sh <name> [minutes=10] [join2-minute=5]
#   DRY_RUN=1 tools/lan-check.sh lan-dry        the server half only: no GUI client; the server runs DRY_MIN (2) minutes
#                                               of the match, the script checks the port, the checksum lines and errors,
#                                               and prints the client command lines it would run
# Env: KEEP_TREE=<dir> (default mods/factorio-rts), SEED (701), MATCH (lua table, default the 4-nation 2048 normal match),
#      PORT (default 34197 + a hash of the name), DRY_RUN, DRY_MIN.
# Output: build/<name>-out/{server.log, client1.log, client2.log}.
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
NAME="${1:?name}"; MINUTES="${2:-10}"; JOIN2="${3:-5}"
SEED="${SEED:-701}"; DRY_MIN="${DRY_MIN:-2}"
DEFAULT_MATCH='{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}'
MATCH="${MATCH:-$DEFAULT_MATCH}"
SRC="${KEEP_TREE:-$RTS_MODS_DIR/factorio-rts}"
DIR="$RTS_BUILD_DIR/$NAME"; OUT="$RTS_BUILD_DIR/$NAME-out"
rm -rf "$DIR" "$OUT"; mkdir -p "$DIR" "$OUT"
cp -R "$SRC" "$DIR/factorio-rts"
M="$DIR/factorio-rts"
python3 - "$M/scripts/debug.lua" "$MATCH" <<'PY'
import re, sys
path, table = sys.argv[1], sys.argv[2]
src = open(path).read()
new, n = re.subn(r'^local AUTOTEST_MATCH = \{.*\}$', 'local AUTOTEST_MATCH = ' + table, src, count=1, flags=re.M)
assert n == 1, "AUTOTEST_MATCH line not found"
new, n = re.subn(r'^local AUTOTEST_ENABLED = false$', 'local AUTOTEST_ENABLED = true', new, count=1, flags=re.M)
assert n == 1 or "AUTOTEST_ENABLED" not in new, "AUTOTEST_ENABLED line not found"  # older trees: always on
open(path, "w").write(new)
PY
sed -i '' "s|^autotest.DURATION = .*|autotest.DURATION = 600 * 60 * 60|" "$M/scripts/ai/autotest.lua"
cp "$RTS_ROOT/tools/probes/perf_lan.lua" "$M/scripts/perf_lan.lua"
printf 'return {period = 600}\n' > "$M/scripts/perf_lan_cfg.lua"
printf '\n-- test copy (tools/lan-check.sh)\nrequire("scripts.perf_lan")\n' >> "$M/control.lua"
cp "$RTS_MODS_DIR/mod-list.json" "$DIR/"
SCFG="$(factorio_isolated_config "$NAME-server")"
SAVE="$OUT/lan.zip"
"$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --create "$SAVE" --map-gen-seed "$SEED" > "$OUT/create.log" 2>&1 \
  || { echo "create failed"; grep -i error "$OUT/create.log" | head; exit 1; }
PORT="${PORT:-$(( 34197 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 500 ) ))}"
while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
"$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --start-server "$SAVE" --port "$PORT" \
  --server-settings "$RTS_ROOT/tools/server-settings.json" > "$OUT/server.log" 2>&1 &
SPID=$!
START=$(date +%s)
until grep -q "\[rts\] diplomacy: Nation match" "$OUT/server.log" 2>/dev/null; do
  sleep 2
  kill -0 "$SPID" 2>/dev/null || { echo "server exited before the match started"; tail -5 "$OUT/server.log"; exit 1; }
  [ $(( $(date +%s) - START )) -ge 240 ] && { echo "no match after 240 s"; kill "$SPID"; exit 1; }
done
echo "server pid $SPID on UDP $PORT: match started after $(( $(date +%s) - START )) s"
lsof -nP -iUDP:"$PORT" 2>/dev/null | tail -1 | awk '{print "  listening:", $1, $2, $9}'

client_cfg() { # <n>: an isolated config whose player-data.json names the player rts-lan-<n>
  local cfg wd
  cfg="$(factorio_isolated_config "$NAME-client$1")"; wd="$(dirname "$cfg")"
  printf '{"service-username": "rts-lan-%s", "service-token": ""}\n' "$1" > "$wd/player-data.json"
  echo "$cfg"
}
client_cmd() { # <n>
  echo "\"$FACTORIO_BIN\" -c \"$(client_cfg "$1")\" --mod-directory \"$DIR\" --mp-connect 127.0.0.1:$PORT" \
    "--window-size 1280x800 --disable-audio"
}

if [ -n "${DRY_RUN:-}" ]; then
  sleep $(( DRY_MIN * 60 ))
  kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
  echo "=== dry run: server half only ($DRY_MIN minutes after the match start) ==="
  grep -E "\[rts\] lan check" "$OUT/server.log" | sed -E 's/^ *[0-9.]+ Script @[^ ]+ //' | tail -6
  echo "=== desync / errors in the server log ==="
  grep -niE "desync" "$OUT/server.log" | head -5 || true
  grep -nE "Error|rror while running|Exception" "$OUT/server.log" | grep -v "Got EOF on stdin" | head -5 || echo "(none)"
  echo "=== the GUI half would run ==="
  echo "  client 1: $(client_cmd 1)"
  echo "  client 2 ($JOIN2 minutes later): $(client_cmd 2)"
  echo "out: $OUT"
  exit 0
fi

# shellcheck disable=SC2046
eval "$(client_cmd 1) > \"$OUT/client1.log\" 2>&1 &"
C1=$!
joins() { grep -c "lan check: player .* joined" "$OUT/server.log"; }
J0=$(date +%s)
until [ "$(joins)" -ge 1 ]; do
  sleep 2
  kill -0 "$C1" 2>/dev/null || { echo "client 1 exited"; break; }
  [ $(( $(date +%s) - J0 )) -ge 180 ] && { echo "client 1 did not join within 180 s"; break; }
done
echo "client 1 joined after $(( $(date +%s) - J0 )) s"
C2=""; HANDOFF=""
J1=$(date +%s)
while [ $(( $(date +%s) - J1 )) -lt $(( MINUTES * 60 )) ]; do
  sleep 5
  if [ -z "$C2" ] && [ $(( $(date +%s) - J1 )) -ge $(( JOIN2 * 60 )) ]; then
    eval "$(client_cmd 2) > \"$OUT/client2.log\" 2>&1 &"
    C2=$!
    echo "client 2 started at minute $JOIN2"
  fi
  if [ -n "$C2" ] && [ -z "$HANDOFF" ] && grep -q "UserWithThatNameAlreadyInGame" "$OUT/server.log"; then
    HANDOFF=1
    echo "client 2 refused (same player name as client 1): handing over, client 1 quits, client 2 joins"
    kill "$C2" "$C1" 2>/dev/null; sleep 3; kill -9 "$C2" "$C1" 2>/dev/null
    eval "$(client_cmd 2) > \"$OUT/client2.log\" 2>&1 &"
    C2=$!
  fi
  kill -0 "$SPID" 2>/dev/null || { echo "server exited"; break; }
done
for p in $C2 $C1; do kill "$p" 2>/dev/null; done
sleep 3
for p in $C2 $C1; do kill -9 "$p" 2>/dev/null; done
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
echo "=== joins ==="
grep -E "lan check: player .* joined|\[JOIN\]|\[LEAVE\]" "$OUT/server.log" | sed -E 's/^ *[0-9.]+ Script @[^ ]+ //'
echo "client 2 joined ${HANDOFF:+by hand-over }(joins in the server log: $(joins))"
FAIL=0
[ "$(joins)" -ge 2 ] || { echo "FAIL: client 2 never joined"; FAIL=1; }
echo "=== desync ==="
for f in "$OUT/server.log" "$OUT/client1.log" "$OUT/client2.log"; do
  [ -f "$f" ] || continue
  n=$(grep -ciE "desync" "$f")
  echo "  $(basename "$f"): $n desync lines"; [ "$n" -gt 0 ] && { grep -iE "desync" "$f" | head -3; FAIL=1; }
done
for n in 1 2; do
  wd="$RTS_BUILD_DIR/runs/$NAME-client$n"
  if ls -d "$wd"/desync-report* >/dev/null 2>&1; then echo "  client $n wrote a desync report: $(ls -d "$wd"/desync-report* | head -1)"; FAIL=1; fi
done
echo "=== checksums (client lines vs the server's) ==="
python3 - "$OUT/server.log" "$OUT/client1.log" "$OUT/client2.log" <<'PY' || FAIL=1
import re, sys, os
def checks(path):
    out = {}
    if not os.path.exists(path): return out
    for line in open(path, errors="replace"):
        m = re.search(r"\[rts\] lan check t(\d+): (.*)", line)
        if m: out[int(m.group(1))] = m.group(2).strip()
    return out
srv = checks(sys.argv[1]); bad = 0
for path in sys.argv[2:]:
    cl = checks(path)
    same = sum(1 for t in cl if srv.get(t) == cl[t])
    diff = [t for t in cl if t in srv and srv[t] != cl[t]]
    print(f"  {os.path.basename(path)}: {len(cl)} check lines, {same} equal to the server's, {len(diff)} differ")
    for t in diff[:3]: print(f"    t{t}\n      server: {srv[t][:200]}\n      client: {cl[t][:200]}")
    bad += len(diff)
sys.exit(1 if bad else 0)
PY
echo "=== Lua errors ==="
grep -nE "Error|rror while running|Exception" "$OUT/server.log" "$OUT/client1.log" "$OUT/client2.log" 2>/dev/null \
  | grep -v "Got EOF on stdin" | head -8 || echo "(none)"
[ "$FAIL" = 0 ] && echo "lan check: PASS" || echo "lan check: FAIL"
echo "out: $OUT"
