#!/usr/bin/env bash
# Divisions stress benchmark (docs/PHASE5-M1.md section 4 "Divisions"): copies the mod (KEEP_TREE or mods/factorio-rts)
# to build/<name>/, adds tools/probes/divisions_stress.lua with the given config, creates the save (the scenario is built
# in on_init), runs `--benchmark --benchmark-verbose all` on it and prints the per-tick summary and PASS/FAIL lines.
#
# Usage: tools/divisions-bench.sh <name> '<lua cfg table>' [ticks=3600] [max-mean-ms=6] [max-tick-ms=20]
#   tools/divisions-bench.sh div-march '{mode = "march", forces = 4, divs = 12, half = 512, leg = 200, start = 120,
#       burst = 1800, comp = {{"rts-walker", 10}, {"rts-walker-heavy", 3}, {"rts-raider", 3}}}' 5400
#   tools/divisions-bench.sh div-mass '{mode = "mass", n = 1000, half = 512, start = 120}' 1800
# Env: SKIP=<ticks> warm-up ticks left out of the statistics (default 60).
#      MODULE=divisions_func runs the functional test (tools/probes/divisions_func.lua) instead of the stress scenario:
#      MODULE=divisions_func tools/divisions-bench.sh div-func '{}' 7200 99 99
set -uo pipefail
source "$(dirname "$0")/factorio-env.sh"
NAME="${1:?name}"; CFG_TABLE="${2:?lua cfg table}"; TICKS="${3:-3600}"; MAX_MEAN="${4:-6}"; MAX_TICK="${5:-20}"
SKIP="${SKIP:-60}"; MODULE="${MODULE:-divisions_stress}"
SRC="${KEEP_TREE:-$RTS_MODS_DIR/factorio-rts}"
factorio_version_guard "$SRC" # the binary must match the tree's info.json
DIR="$RTS_BUILD_DIR/$NAME"           # the mod directory of the run
OUT="$RTS_BUILD_DIR/$NAME-out"       # save, logs, benchmark output (a zip in the mod directory would load as a mod)
rm -rf "$DIR" "$OUT"; mkdir -p "$DIR" "$OUT"
cp -R "$SRC" "$DIR/factorio-rts"
M="$DIR/factorio-rts"
cp "$RTS_ROOT/tools/probes/$MODULE.lua" "$M/scripts/$MODULE.lua"
printf 'return %s\n' "$CFG_TABLE" > "$M/scripts/div_stress_cfg.lua"
printf '\n-- test copy (tools/divisions-bench.sh)\nrequire("scripts.%s")\n' "$MODULE" >> "$M/control.lua"
cp "$RTS_MODS_DIR/mod-list.json" "$DIR/"
CFG="$(factorio_isolated_config "$NAME")"
WD="$RTS_BUILD_DIR/runs/$NAME"
SAVE="$OUT/stress.zip"
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --map-gen-seed 4242 --create "$SAVE" > "$OUT/create.out" 2>&1 \
  || { echo "create failed:"; grep -iE "error" "$OUT/create.out" | head; exit 1; }
cp "$WD/factorio-current.log" "$OUT/create.log"
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --benchmark "$SAVE" --benchmark-ticks "$TICKS" \
  --benchmark-verbose all > "$OUT/bench.out" 2>&1
cp "$WD/factorio-current.log" "$OUT/bench.log"
echo "=== $NAME ($TICKS ticks) ==="
grep -h "div stress\|div func\|orders queue" "$OUT/create.log" "$OUT/bench.log" | sed -E 's/^ *[0-9.]+ Script @[^ ]+ //' | cut -c1-260
echo "=== errors ==="
grep -hnE "Error|rror while running|Exception" "$OUT/create.log" "$OUT/bench.log" | head -10 || true
python3 - "$OUT/bench.out" "$SKIP" "$MAX_MEAN" "$MAX_TICK" <<'PY'
import sys
path, skip, max_mean, max_tick = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
hdr, rows = None, []
for line in open(path, errors="replace"):
    if line.startswith("tick,"): hdr = line.strip().strip(",").split(",")
    elif line.startswith("t") and line[1:2].isdigit():
        v = line.strip().strip(",").split(","); rows.append([int(v[0][1:])] + [int(x) for x in v[1:]])
if not rows:
    print("no benchmark rows"); sys.exit(1)
rows = [r for r in rows if r[0] >= skip]
n = len(rows)
cols = ["wholeUpdate", "entityUpdate", "pathFinder", "scriptUpdate"]
print(f"=== benchmark: {n} ticks from tick {skip} (ms) ===")
for c in cols:
    i = hdr.index(c); xs = sorted(r[i] / 1e6 for r in rows)
    print(f"  {c:14s} mean {sum(xs)/n:7.3f}  p50 {xs[n//2]:7.3f}  p95 {xs[int(n*0.95)]:7.3f}  max {xs[-1]:7.3f}")
w, p, s = hdr.index("wholeUpdate"), hdr.index("pathFinder"), hdr.index("scriptUpdate")
worst = sorted(rows, key=lambda r: -r[w])[:5]
print("  worst ticks: " + ", ".join(f"t{r[0]} {r[w]/1e6:.1f} (path {r[p]/1e6:.1f}, script {r[s]/1e6:.1f})" for r in worst))
mean = sum(r[w] for r in rows) / n / 1e6
mx = max(r[w] for r in rows) / 1e6
over = [r for r in rows if r[w] / 1e6 > 16.67]
# Order ticks: the order queue or the pathfinder worked (scriptUpdate + pathFinder > 1 ms). Columns this scenario has no
# entities for (belts, circuits, electric networks) only collect time when the OS preempts the game thread on a busy
# machine; a slow tick whose time sits there is noise, and the line says so.
noise_cols = [hdr.index(c) for c in ("transportLinesUpdate", "controlBehaviorUpdate", "electricNetworkUpdate")]
order = [r for r in rows if (r[s] + r[p]) / 1e6 > 1.0]
omx = max((r[w] for r in order), default=0) / 1e6
print(f"  ticks over 16.67 ms: {len(over)}" + "".join(
    f"; t{r[0]} {r[w]/1e6:.1f} ms of which {sum(r[i] for i in noise_cols)/1e6:.1f} in belt/circuit/power columns "
    f"(empty here: preemption)" for r in over[:5]))
print(f"  order ticks (script + pathFinder > 1 ms): {len(order)}, worst {omx:.2f} ms")
print(f"check mean_ms_per_tick: {'PASS' if mean <= max_mean else 'FAIL'} {mean:.3f} ms (limit {max_mean})")
print(f"check max_order_tick_ms: {'PASS' if omx <= max_tick else 'FAIL'} {omx:.2f} ms (limit {max_tick}); "
      f"worst tick overall {mx:.2f} ms")
PY
