#!/usr/bin/env bash
# Phase 5 M3 perf: heavy mode on a 4-nation match (docs/PHASE5-M3.md D9 and section 4 "Perf / determinism";
# docs/qa/phase5-perf-notes.md). Heavy mode (`factorio --heavy`, single player with graphics) saves, loads and compares the
# whole game state every tick, so anything that a save and load changes (state outside storage, pairs order that a
# reload rebuilds, a module cache that decides something) shows up as a heavy-mode desync on the very tick it happens.
#   1. a test copy of the mod plays a 4-nation normal AI match on a headless server (the autotest starts it at tick 120)
#      for WARMUP seconds after the match start, then the server quits and saves it (start.zip);
#   2. the GUI client loads start.zip with --heavy and runs MINUTES minutes of wall clock (heavy mode is slow: the log's
#      "[rts] lan check t<tick>" lines of tools/probes/perf_lan.lua, every 10 s of game time, show how far it got);
#   3. FAIL on any "desync" line (any case) in the client log or a desync report in its write-data directory; Lua errors
#      are listed.
# Usage: tools/heavy-mode.sh <name> [minutes=10]
#   SAVELOAD=1 [SAVE_MIN=5 END_MIN=10] tools/heavy-mode.sh sl-701   the headless counterpart: the same match played on
#                                                through a save and load must log the same lines as without (see below)
#   DRY_RUN=1 tools/heavy-mode.sh heavy-dry      steps 1 and a headless check of the save (a 600-tick benchmark of
#                                                start.zip with the same mods: it must load and run without errors), then
#                                                prints the GUI command line of step 2
# Env: KEEP_TREE=<dir> (default mods/factorio-rts), SEED (701), WARMUP (seconds, default 60), MATCH (lua table),
#      START_SAVE=<zip> heavy mode from that save instead of the warm-up (a save of the same tree with perf_lan).
# Output: build/<name>-out/{create.log, warmup.log, start.zip, heavy.log | bench.out}.
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
NAME="${1:?name}"; MINUTES="${2:-10}"
SEED="${SEED:-701}"; WARMUP="${WARMUP:-60}"
DEFAULT_MATCH='{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}'
MATCH="${MATCH:-$DEFAULT_MATCH}"
SRC="${KEEP_TREE:-$RTS_MODS_DIR/factorio-rts}"
factorio_version_guard "$SRC" # the binary must match the tree's info.json
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
printf '\n-- test copy (tools/heavy-mode.sh)\nrequire("scripts.perf_lan")\n' >> "$M/control.lua"
cp "$RTS_MODS_DIR/mod-list.json" "$DIR/"
SCFG="$(factorio_isolated_config "$NAME-server")"
SAVE="$OUT/start.zip"
if [ -n "${SAVELOAD:-}" ]; then
  # Headless save/load equivalence (no GUI): run A plays on a server from a fresh save at speed 8 and saves at match
  # minute SAVE_MIN (game.server_save); run B is a benchmark of that save to the same end tick. Every checksum line and
  # every "[rts]" event line after the save must be the same in both: a difference is state that a save and load changed.
  SAVE_MIN="${SAVE_MIN:-5}"; END_MIN="${END_MIN:-10}"
  T=$(( (120 + SAVE_MIN * 3600) / 600 * 600 )); E=$(( (120 + END_MIN * 3600) / 600 * 600 ))
  # a server autosave (every 10 game minutes, tools/server-settings.json) on the same tick swallows game.server_save
  [ $(( T % 36000 )) -eq 0 ] && T=$(( T + 600 ))
  printf 'return {period = 600, save_at = %d, speed = 8}\n' "$T" > "$M/scripts/perf_lan_cfg.lua"
  "$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --create "$SAVE" --map-gen-seed "$SEED" > "$OUT/create.log" 2>&1 \
    || { echo "create failed"; exit 1; }
  PORT=$(( 36000 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 1000 ) ))
  while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
  WDS="$(dirname "$SCFG")"; mkdir -p "$WDS/saves"; rm -f "$WDS/saves/perf-lan-$T.zip" # server_save needs the directory
  "$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --start-server "$SAVE" --port "$PORT" \
    --server-settings "$RTS_ROOT/tools/server-settings.json" > "$OUT/run-a.log" 2>&1 &
  SPID=$!; START=$(date +%s)
  until grep -q "\[rts\] lan check t$E:" "$OUT/run-a.log" 2>/dev/null; do
    sleep 3
    kill -0 "$SPID" 2>/dev/null || { echo "run A exited early"; break; }
    [ $(( $(date +%s) - START )) -ge 3000 ] && { echo "run A: cap reached"; break; }
  done
  kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
  [ -f "$WDS/saves/perf-lan-$T.zip" ] || { echo "no save at tick $T"; exit 1; }
  cp "$WDS/saves/perf-lan-$T.zip" "$OUT/at-$T.zip"
  "$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --benchmark "$OUT/at-$T.zip" --benchmark-ticks $(( E - T + 60 )) \
    > "$OUT/run-b.out" 2>&1
  cp "$WDS/factorio-current.log" "$OUT/run-b.log"
  echo "=== save/load equivalence: saved at tick $T (match minute $SAVE_MIN), compared to tick $E ==="
  python3 - "$OUT/run-a.log" "$OUT/run-b.log" "$T" "$E" <<'PYC'
import re, sys
pa, pb, T, E = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
PREFIX = re.compile(r"^ *[0-9.]+ Script @__factorio-rts__/[^ ]+ ")
TIMING = re.compile(r"perf|wall clock| ms\b|ms/tick|ms per|Duration|UPS|saving perf-lan|player .* joined|rails: geometry read", re.I)
# (rails.lua re-reads its module-local rail geometry, read-only, on the first survey after a load: one log line)
def after(path):
    # from the first checksum line after the save tick (run B starts on the tick after it) to the one at tick E
    out, on = [], False
    for line in open(path, errors="replace"):
        if "[rts]" not in line: continue
        l = PREFIX.sub("", line.rstrip("\n"))
        m = re.search(r"lan check t(\d+):", l)
        if not on:
            if m and int(m.group(1)) > T: on = True
            else: continue
        if m and int(m.group(1)) > E: break
        if TIMING.search(l): continue
        out.append(l)
        if m and int(m.group(1)) == E: break  # run B ends a second after tick E
    return out
a, b = after(pa), after(pb)
ka = [l for l in a if "lan check t" in l]; kb = [l for l in b if "lan check t" in l]
kdiff = [i for i in range(min(len(ka), len(kb))) if ka[i] != kb[i]]
import difflib
ops = [op for op in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if op[0] != "equal"]
nd = sum(max(i2 - i1, j2 - j1) for _, i1, i2, j1, j2 in ops)
print(f"  state checksums: run A {len(ka)}, run B {len(kb)}, {len(kdiff)} differ")
for i in kdiff[:3]: print(f"    A: {ka[i][:200]}\n    B: {kb[i][:200]}")
print(f"  all [rts] lines after the save: run A {len(a)}, run B {len(b)}, {nd} in {len(ops)} differing blocks")
for tag, i1, i2, j1, j2 in ops[:4]:
    for l in a[i1:min(i2, i1 + 2)]: print(f"    A: {l[:200]}")
    for l in b[j1:min(j2, j1 + 2)]: print(f"    B: {l[:200]}")
sys.exit(1 if kdiff or not ka or len(ka) != len(kb) or ops else 0)
PYC
  RC=$?
  grep -nE "Error|rror while running|Exception" "$OUT/run-a.log" "$OUT/run-b.log" | grep -v "Got EOF on stdin" | head -5
  [ "$RC" = 0 ] && echo "save/load equivalence: PASS" || echo "save/load equivalence: FAIL"
  echo "out: $OUT"
  exit "$RC"
fi
if [ -n "${START_SAVE:-}" ]; then
  # a later moment of a match (e.g. a save of SAVELOAD=1 at minute 20: rail surveys, wars) instead of the warm-up
  cp "$START_SAVE" "$SAVE"
  echo "start save: $START_SAVE"
else
"$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --create "$SAVE" --map-gen-seed "$SEED" > "$OUT/create.log" 2>&1 \
  || { echo "create failed"; grep -i error "$OUT/create.log" | head; exit 1; }
PORT=$(( 36000 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 1000 ) ))
while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
"$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --start-server "$SAVE" --port "$PORT" \
  --server-settings "$RTS_ROOT/tools/server-settings.json" > "$OUT/warmup.log" 2>&1 &
SPID=$!
START=$(date +%s)
until grep -q "\[rts\] diplomacy: Nation match" "$OUT/warmup.log" 2>/dev/null; do
  sleep 2
  kill -0 "$SPID" 2>/dev/null || { echo "server exited before the match started"; exit 1; }
  [ $(( $(date +%s) - START )) -ge 240 ] && { echo "no match after 240 s"; kill "$SPID"; exit 1; }
done
sleep "$WARMUP"
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null # a headless server saves the map when it quits
grep -q "Saving map as" "$OUT/warmup.log" || { echo "the server did not save"; exit 1; }
echo "start save: $SAVE ($(grep -E '\[rts\] lan check t' "$OUT/warmup.log" | tail -1 | sed -E 's/.*lan check (t[0-9]+).*/\1/'))"
fi
CCFG="$(factorio_isolated_config "$NAME-client")"
CMD=("$FACTORIO_BIN" -c "$CCFG" --mod-directory "$DIR" --load-game "$SAVE" --heavy --window-size 1280x800 --disable-audio)
if [ -n "${DRY_RUN:-}" ]; then
  echo "=== dry run: the save loads and runs headless (600-tick benchmark) ==="
  "$FACTORIO_BIN" -c "$SCFG" --mod-directory "$DIR" --benchmark "$SAVE" --benchmark-ticks 600 > "$OUT/bench.out" 2>&1
  grep -E "Performed|avg:" "$OUT/bench.out" | head -3
  grep -nE "Error|rror while running|Exception" "$OUT/bench.out" "$OUT/warmup.log" | grep -v "Got EOF on stdin" | head -5 \
    || echo "(no errors)"
  echo "=== the GUI half would run (heavy mode, $MINUTES minutes of wall clock) ==="
  printf '  '; printf '"%s" ' "${CMD[@]}"; echo
  echo "out: $OUT"
  exit 0
fi
"${CMD[@]}" > "$OUT/heavy.log" 2>&1 &
CPID=$!
C0=$(date +%s)
while [ $(( $(date +%s) - C0 )) -lt $(( MINUTES * 60 )) ]; do
  sleep 5
  kill -0 "$CPID" 2>/dev/null || { echo "client exited after $(( $(date +%s) - C0 )) s"; break; }
done
kill "$CPID" 2>/dev/null; sleep 3; kill -9 "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null
echo "=== heavy mode: $(grep -cE '\[rts\] lan check t' "$OUT/heavy.log") checksum lines, last: $(grep -E '\[rts\] lan check t' "$OUT/heavy.log" | tail -1 | sed -E 's/.*lan check (t[0-9]+).*/\1/') ==="
FAIL=0
n=$(grep -ciE "desync" "$OUT/heavy.log"); echo "desync lines: $n"; [ "$n" -gt 0 ] && { grep -iE "desync" "$OUT/heavy.log" | head -5; FAIL=1; }
WD="$(dirname "$CCFG")"
if ls -d "$WD"/desync-report* >/dev/null 2>&1; then echo "desync report: $(ls -d "$WD"/desync-report* | head -1)"; FAIL=1; fi
grep -iE "heavy" "$OUT/heavy.log" | head -5
echo "=== Lua errors ==="
grep -nE "Error|rror while running|Exception" "$OUT/heavy.log" | head -8 || echo "(none)"
[ "$FAIL" = 0 ] && echo "heavy mode: PASS" || echo "heavy mode: FAIL"
echo "out: $OUT"
