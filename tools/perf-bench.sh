#!/usr/bin/env bash
# Phase 5 M3 performance bench (docs/PHASE5-M3.md D9 and section 4 "Perf / determinism"; docs/qa/phase5-perf-notes.md).
# Runs the game with `--benchmark --benchmark-verbose all` (as fast as the machine goes, every tick timed by the engine)
# on a test copy of the mod with PERF=1 profiling and the tick marks of tools/probes/perf_marks.lua, then prints:
#   - per-tick statistics (mean, p50, p95, p99, max) of wholeUpdate, scriptUpdate, entityUpdate, pathFinder, trains;
#   - the ticks over 16.67 ms (a dropped frame at 60 UPS) and the ticks whose script time is over 3 ms (the AI cap of D9),
#     each with the marks of tools/probes/perf_marks.lua (what planning work ran in it);
#   - per game minute: mean and worst script and whole-tick time;
#   - the per-module PERF summary of tools/perf-log.sh over the benchmarked minutes.
#
# Modes:
#   tools/perf-bench.sh match <name> '<lua match table>' <minutes>
#       A match from a fresh save: the save is --create'd with SEED (default 701) and the headless autotest starts the
#       match at tick 120 (no players connected), exactly as tools/autotest-run.sh does; the benchmark runs minutes + 3 s.
#       tools/perf-bench.sh match pb-701 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
#           enemy_brain = "ai"}' 20
#   tools/perf-bench.sh scene <name> [bench-minutes=5]
#       The M3 budget scene: 4 nations, 16 cities, 600 units, 40 trains (tools/probes/perf_scene.lua). A headless server
#       plays a 4-nation normal match at SCENE_SPEED (default 8) to minute SCENE_AT (default 10); the fixture then founds
#       cities up to 4 per nation, spawns units up to 150 per nation (2/3 walkers, 1/3 drones) in divisions that march
#       between the nation's cities, builds 10 freight lines per nation (2 depots and a straight track each, on a lab
#       surface) with one rails.lua cargo train each, lets it settle for a minute at speed 1 and saves it with
#       game.server_save ("perf-scene"). The benchmark then runs that save for bench-minutes. REALTIME=<minutes> also
#       plays the saved scene on a headless server at speed 1 for that long and prints the wall clock of every game
#       minute (60 UPS = 60.0 s per minute).
#   tools/perf-bench.sh bench <name> <save.zip> [minutes=5]
#       Benchmark an existing save with the copy of an earlier run named <name> (its mod directory build/<name>/).
#   tools/perf-bench.sh realtime <name> <save.zip> [minutes=5]
#       Play an existing save (a scene) on a headless server with the copy of run <name> and print the scene fixture's
#       wall clock per game minute (60.0 s = 60 UPS at speed 1) and the PERF module totals.
#
# Env: KEEP_TREE=<dir> mod tree (default mods/factorio-rts); SEED=<n> map seed (match, scene; default 701);
#      VARIANT=sa|base; PERF=0 turns the per-module profiling off; MARKS=0 leaves the tick marks out;
#      EXTRA_LUA=<file> one more test module (required after the marks); SKIP=<ticks> warm-up left out (default 0);
#      SCENE_AT=<min>, SCENE_SPEED=<n>, SCENE_CAP=<s> (scene creation wall-clock cap, default 1500), REALTIME=<min>;
#      ROUTE_MARKS=1 also times every ai/layout.lua A* route call (verbose).
# Output: build/<name>-out/{create.out, bench.out (per-tick CSV), bench.log (game log), scene.log, realtime.log}.
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
MODE="${1:?mode: match | scene | bench}"; NAME="${2:?name}"
SEED="${SEED:-701}"; VARIANT="${VARIANT:-sa}"; SKIP="${SKIP:-0}"
SRC="${KEEP_TREE:-$RTS_MODS_DIR/factorio-rts}"
factorio_version_guard "$SRC" # the binary must match the tree's info.json
DIR="$RTS_BUILD_DIR/$NAME"; OUT="$RTS_BUILD_DIR/$NAME-out"
CFG="$(factorio_isolated_config "$NAME")"; WD="$RTS_BUILD_DIR/runs/$NAME"
SCENE_MATCH='{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}'

# Copy the tree into build/<name>/factorio-rts with the match table, the autotest length and the test modules.
prepare() { # <match table> <autotest minutes> <extra modules...>
  local match="$1" minutes="$2"; shift 2
  rm -rf "$DIR" "$OUT"; mkdir -p "$DIR" "$OUT"
  cp -R "$SRC" "$DIR/factorio-rts"
  local M="$DIR/factorio-rts"
  python3 - "$M/scripts/debug.lua" "$match" <<'PY'
import re, sys
path, table = sys.argv[1], sys.argv[2]
src = open(path).read()
new, n = re.subn(r'^local AUTOTEST_MATCH = \{.*\}$', 'local AUTOTEST_MATCH = ' + table, src, count=1, flags=re.M)
assert n == 1, "AUTOTEST_MATCH line not found"
new, n = re.subn(r'^local AUTOTEST_ENABLED = false$', 'local AUTOTEST_ENABLED = true', new, count=1, flags=re.M)
assert n == 1 or "AUTOTEST_ENABLED" not in new, "AUTOTEST_ENABLED line not found"  # older trees: always on
open(path, "w").write(new)
PY
  sed -i '' "s|^autotest.DURATION = .*|autotest.DURATION = ${minutes} * 60 * 60|" "$M/scripts/ai/autotest.lua"
  {
    printf '\n-- test copy (tools/perf-bench.sh)\n'
    [ "${PERF:-1}" != "0" ] && printf 'require("scripts.events").enable_profiling()\n'
    local f
    for f in "$@"; do
      cp "$f" "$M/scripts/$(basename "$f")"
      printf 'require("scripts.%s")\n' "$(basename "$f" .lua)"
    done
  } >> "$M/control.lua"
  [ -n "${ROUTE_MARKS:-}" ] && printf 'return {route = true}\n' > "$M/scripts/perf_marks_cfg.lua"
  if [ "$VARIANT" = "base" ]; then
    printf '{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":false},{"name":"recycler","enabled":false},{"name":"quality","enabled":false},{"name":"space-age","enabled":false},{"name":"factorio-rts","enabled":true}]}\n' > "$DIR/mod-list.json"
  else
    cp "$RTS_MODS_DIR/mod-list.json" "$DIR/"
  fi
}

extras() {
  local list=()
  [ "${MARKS:-1}" != "0" ] && list+=("$RTS_ROOT/tools/probes/perf_marks.lua")
  [ -n "${EXTRA_LUA:-}" ] && list+=("$EXTRA_LUA")
  echo "${list[@]:-}"
}

bench() { # <save> <ticks>
  local save="$1" ticks="$2"
  echo "benchmark: $ticks ticks of $(basename "$save") ..."
  "$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --benchmark "$save" --benchmark-ticks "$ticks" \
    --benchmark-verbose all > "$OUT/bench.out" 2>&1
  cp "$WD/factorio-current.log" "$OUT/bench.log"
}

report() {
  echo "=== $NAME: benchmark of $(grep -c '^t[0-9]' "$OUT/bench.out") ticks ==="
  echo "=== errors ==="
  grep -hnE "Error|rror while running|Exception" "$OUT/bench.log" "$OUT/create.out" 2>/dev/null | head -10 || true
  python3 - "$OUT/bench.out" "$OUT/bench.log" "$SKIP" <<'PY'
import re, sys
path, logpath, skip = sys.argv[1], sys.argv[2], int(sys.argv[3])
hdr, rows = None, []
for line in open(path, errors="replace"):
    if line.startswith("tick,"): hdr = line.strip().strip(",").split(",")
    elif line.startswith("t") and line[1:2].isdigit():
        v = line.strip().strip(",").split(",")
        rows.append([int(v[0][1:])] + [int(x) for x in v[1:]])
if not rows:
    print("no benchmark rows"); sys.exit(1)
marks, calls = {}, {}
origin = None
for line in open(logpath, errors="replace"):
    m = re.search(r"\[rts\] perf mark origin t(\d+)", line)
    if m and origin is None: origin = int(m.group(1))
    m = re.search(r"\[rts\] perf mark t(\d+): (.*)", line)
    if m: marks[int(m.group(1))] = m.group(2).strip()
    m = re.search(r"\[rts\] perf call t(\d+) d(\d+) (.*?): Duration: ([0-9.]+)ms", line)
    if m: calls.setdefault(int(m.group(1)), []).append((int(m.group(2)), m.group(3), float(m.group(4))))
def top_calls(t):
    cs = calls.get(t) or calls.get(t + 1) or []
    out = []
    for d, label, v in sorted(cs, key=lambda c: (c[0], -c[2])):
        if v >= 0.5 and d <= 3: out.append(f"{'>' * max(0, d - 1)}{label} {v:.1f}")
    return ", ".join(out[:6])
def culprit(t):
    # the heaviest timed call of the tick (d0 = a traced on_nth_tick handler, d1+ = perf_marks wrappers), then the
    # deepest call that still holds half of it
    cs = calls.get(t) or calls.get(t + 1) or []
    if not cs: return None
    top = max(cs, key=lambda c: c[2])
    best = top
    for d, label, v in cs:
        if d > best[0] and v >= 0.5 * top[2] and v >= 1.0: best = (d, label, v)
    return re.sub(r" rts-[a-z0-9-]+$", "", best[1])
# benchmark rows count from t0 = the first tick run; on a loaded save the marks carry game ticks from `origin` on
off = origin if (origin is not None and origin > 1) else 0
if off:
    marks = {t - off: v for t, v in marks.items()}
    calls = {t - off: v for t, v in calls.items()}
rows = [r for r in rows if r[0] >= skip]
n = len(rows)
col = {c: hdr.index(c) for c in hdr}
ms = lambda r, c: r[col[c]] / 1e6
print(f"=== per tick (ms), {n} ticks from t{rows[0][0]} ===")
for c in ("wholeUpdate", "scriptUpdate", "entityUpdate", "pathFinder", "trains", "chartUpdate"):
    if c not in col: continue
    xs = sorted(ms(r, c) for r in rows)
    print(f"  {c:13s} mean {sum(xs)/n:7.3f}  p50 {xs[n//2]:7.3f}  p95 {xs[int(n*0.95)]:7.3f}  "
          f"p99 {xs[min(n-1, int(n*0.99))]:7.3f}  max {xs[-1]:8.3f}")
mean_whole = sum(ms(r, "wholeUpdate") for r in rows) / n
print(f"  UPS capacity at the mean tick: {1000 / mean_whole:.0f} (60 needs <= 16.67 ms per tick)")
def mark_of(t):
    # the marks of a tick are logged with game.tick; the benchmark row t<N> runs game tick N (the save's tick + index)
    return marks.get(t) or marks.get(t + 1) or ""
over = [r for r in rows if ms(r, "wholeUpdate") > 16.67]
sover = [r for r in rows if ms(r, "scriptUpdate") > 3.0]
print(f"=== ticks over 16.67 ms whole: {len(over)}; ticks over 3 ms script: {len(sover)} ===")
worst = sorted(rows, key=lambda r: -ms(r, "scriptUpdate"))[:15]
print("=== worst script ticks ===")
for r in worst:
    print(f"  t{r[0]:<7d} script {ms(r, 'scriptUpdate'):8.2f}  whole {ms(r, 'wholeUpdate'):8.2f}  "
          f"path {ms(r, 'pathFinder'):6.2f}  entity {ms(r, 'entityUpdate'):6.2f}  {(top_calls(r[0]) or mark_of(r[0]))[:170]}")
worstw = [r for r in sorted(rows, key=lambda r: -ms(r, "wholeUpdate"))[:8] if r not in worst]
if worstw:
    print("=== worst whole ticks (not above) ===")
    for r in worstw:
        print(f"  t{r[0]:<7d} whole {ms(r, 'wholeUpdate'):8.2f}  script {ms(r, 'scriptUpdate'):6.2f}  "
              f"path {ms(r, 'pathFinder'):6.2f}  entity {ms(r, 'entityUpdate'):6.2f}  {mark_of(r[0])[:120]}")
# script > 3 ms ticks grouped by the timed call that holds most of them (else by their marks)
groups = {}
for r in sover:
    key = culprit(r[0]) or re.sub(r" x\d+", "", mark_of(r[0])) or "(no mark)"
    g = groups.setdefault(key, [0, 0.0, 0.0])
    g[0] += 1; g[1] += ms(r, "scriptUpdate"); g[2] = max(g[2], ms(r, "scriptUpdate"))
if groups:
    print("=== script > 3 ms ticks by marks: count, total ms, worst ===")
    for key, g in sorted(groups.items(), key=lambda kv: -kv[1][1])[:15]:
        print(f"  {g[0]:5d} {g[1]:9.1f} {g[2]:8.2f}  {key[:140]}")
if calls:
    fs = {}
    for t, cs in calls.items():
        for d, label, v in cs:
            f = fs.setdefault(re.sub(r" rts-[a-z0-9-]+$", "", label), [0, 0.0, 0.0, 0])
            f[0] += 1; f[1] += v; f[2] = max(f[2], v); f[3] += v > 3.0
    print("=== timed calls (tools/probes/perf_marks.lua): calls, mean ms, worst ms, calls over 3 ms ===")
    for label, f in sorted(fs.items(), key=lambda kv: -kv[1][2])[:30]:
        print(f"  {label:28s} {f[0]:7d} {f[1]/f[0]:8.3f} {f[2]:9.2f} {f[3]:6d}")
print("=== per minute of the benchmark (ms): script mean / worst, whole mean / worst, ticks script > 3 ms ===")
by = {}
for r in rows:
    by.setdefault(r[0] // 3600, []).append(r)
for m in sorted(by):
    rs = by[m]
    s = [ms(r, "scriptUpdate") for r in rs]; w = [ms(r, "wholeUpdate") for r in rs]
    print(f"  minute {m:3d}: script {sum(s)/len(s):6.3f} / {max(s):8.2f}   whole {sum(w)/len(w):6.3f} / {max(w):8.2f}"
          f"   >3ms {sum(1 for x in s if x > 3)}")
PY
  echo "=== PERF per module (tools/perf-log.sh, all benchmarked minutes) ==="
  "$RTS_ROOT/tools/perf-log.sh" "$OUT/bench.log" 1 0 2>/dev/null || true
}

case "$MODE" in
  match)
    MATCH="${3:?lua match table}"; MIN="${4:?minutes}"
    # shellcheck disable=SC2046
    prepare "$MATCH" "$MIN" $(extras)
    SAVE="$OUT/match.zip"
    "$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --create "$SAVE" --map-gen-seed "$SEED" > "$OUT/create.out" 2>&1 \
      || { echo "create failed:"; grep -iE "error" "$OUT/create.out" | head; exit 1; }
    bench "$SAVE" $(( MIN * 3600 + 180 ))
    report
    ;;
  scene)
    BMIN="${3:-5}"; SCENE_AT="${SCENE_AT:-10}"; SCENE_SPEED="${SCENE_SPEED:-8}"; SCENE_CAP="${SCENE_CAP:-1500}"
    # shellcheck disable=SC2046
    prepare "$SCENE_MATCH" 600 "$RTS_ROOT/tools/probes/perf_scene.lua" $(extras)
    printf 'return {at_minute = %s, speed = %s}\n' "$SCENE_AT" "$SCENE_SPEED" > "$DIR/factorio-rts/scripts/perf_scene_cfg.lua"
    SAVE0="$OUT/start.zip"
    "$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --create "$SAVE0" --map-gen-seed "$SEED" > "$OUT/create.out" 2>&1 \
      || { echo "create failed:"; grep -iE "error" "$OUT/create.out" | head; exit 1; }
    PORT=$(( 38000 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 2000 ) ))
    while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
    mkdir -p "$WD/saves"; rm -f "$WD/saves/perf-scene.zip" # game.server_save needs the directory
    "$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --start-server "$SAVE0" --port "$PORT" \
      --server-settings "$RTS_ROOT/tools/server-settings.json" > "$OUT/scene.log" 2>&1 &
    PID=$!; START=$(date +%s)
    until grep -q "\[rts\] perf scene saved" "$OUT/scene.log" 2>/dev/null; do
      sleep 3
      kill -0 "$PID" 2>/dev/null || { echo "scene server exited early"; break; }
      [ $(( $(date +%s) - START )) -ge "$SCENE_CAP" ] && { echo "scene cap ${SCENE_CAP}s reached"; break; }
    done
    sleep 5 # the save is written after the tick that asked for it
    kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
    grep -E "\[rts\] perf scene" "$OUT/scene.log" | sed -E 's/^ *[0-9.]+ Script @[^ ]+ //' | cut -c1-300
    grep -hnE "Error|rror while running|Exception" "$OUT/scene.log" | head -5 || true
    [ -f "$WD/saves/perf-scene.zip" ] || { echo "no scene save ($WD/saves/perf-scene.zip)"; exit 1; }
    cp "$WD/saves/perf-scene.zip" "$OUT/scene.zip"
    bench "$OUT/scene.zip" $(( BMIN * 3600 ))
    report
    if [ -n "${REALTIME:-}" ]; then
      echo "=== realtime: the scene save on a headless server at speed 1 for $REALTIME minutes ==="
      "$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --start-server "$OUT/scene.zip" --port "$PORT" \
        --server-settings "$RTS_ROOT/tools/server-settings.json" > "$OUT/realtime.log" 2>&1 &
      PID=$!; START=$(date +%s)
      while [ $(( $(date +%s) - START )) -lt $(( REALTIME * 60 + 40 )) ]; do
        sleep 5; kill -0 "$PID" 2>/dev/null || break
      done
      kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
      grep -E "\[rts\] perf scene minute" "$OUT/realtime.log" | sed -E 's/^ *[0-9.]+ Script @[^ ]+ //'
      "$RTS_ROOT/tools/perf-log.sh" "$OUT/realtime.log" 2 0 2>/dev/null | head -40 || true
    fi
    ;;
  realtime)
    SAVE="${3:?save}"; RMIN="${4:-5}"
    [ -d "$DIR/factorio-rts" ] || { echo "no copy at $DIR (run match or scene first)"; exit 1; }
    mkdir -p "$OUT"
    PORT=$(( 38000 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 2000 ) ))
    while lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; do PORT=$(( PORT + 1 )); done
    "$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --start-server "$SAVE" --port "$PORT" \
      --server-settings "$RTS_ROOT/tools/server-settings.json" > "$OUT/realtime.log" 2>&1 &
    PID=$!; START=$(date +%s)
    while [ $(( $(date +%s) - START )) -lt $(( RMIN * 60 + 40 )) ]; do
      sleep 5; kill -0 "$PID" 2>/dev/null || break
    done
    kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
    echo "=== $NAME: $(basename "$SAVE") on a headless server at its saved game speed, $RMIN minutes ==="
    grep -E "\[rts\] perf scene minute" "$OUT/realtime.log" | sed -E 's/^ *[0-9.]+ Script @[^ ]+ //'
    grep -nE "rror while running|Exception" "$OUT/realtime.log" | head -3
    "$RTS_ROOT/tools/perf-log.sh" "$OUT/realtime.log" 2 0 2>/dev/null | grep -E "= (all|AI|M2|M3)" || true
    ;;
  bench)
    SAVE="${3:?save}"; BMIN="${4:-5}"
    [ -d "$DIR/factorio-rts" ] || { echo "no copy at $DIR (run match or scene first)"; exit 1; }
    mkdir -p "$OUT"
    bench "$SAVE" $(( BMIN * 3600 ))
    report
    ;;
  *) echo "unknown mode $MODE"; exit 1 ;;
esac
echo "out: $OUT"
