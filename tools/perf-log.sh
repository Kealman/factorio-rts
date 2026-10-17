#!/usr/bin/env bash
# Summarise the PERF=1 lines of a run log (docs/qa/phase5-perf-notes.md): the "[rts] perf tick ..." per-module lines of
# scripts/events.lua, the AI autotest's "ai perf minute N" lines (AI time per tick, wall clock per game minute) and the
# scheduler's "[rts] sched:" lines (scripts/sched.lua).
#
# Usage: tools/perf-log.sh <log> [first-minute=1] [last-minute=last]
#   tools/perf-log.sh build/p5m3perf-base701-server.log 16 20     the last five minutes of a 20-minute run
# Minute n is the n-th "[rts] perf tick" line (one per 3600 ticks since the save was created or loaded); the AI lines
# use the AI autotest's own minute numbers (minutes since the match started), which run one behind on a fresh save.
# Groups: M2 = the M2 modules of docs/qa/phase5-m2-integration-notes.md 5.3, M3 = the M3 modules, AI = ai/* labels,
# all = every label. UPS of a minute = 3600 / wall-clock seconds (only meaningful at game speed 1).
set -uo pipefail
LOG="${1:?log}"; FIRST="${2:-1}"; LAST="${3:-0}"
python3 - "$LOG" "$FIRST" "$LAST" <<'PY'
import re, sys
path, first, last = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
DUR = r"Duration: ([0-9.]+)ms"
M2 = {"population", "labor", "treasury", "market", "marketgui", "diplomacy", "diplomacygui", "wars", "warsupply",
      "capture", "garrison", "strategic", "world", "targeting"}
M3 = {"age3", "rare", "sinks", "air", "fronts", "belts", "trainswar", "worldgen", "sched"}
minutes = []          # [{label: (ms, calls)}]
ai_tick, wall, parts = {}, {}, {}
sched = []
for line in open(path, errors="replace"):
    if "[rts] perf tick" in line:
        minutes.append({})
    if "[rts] perf" in line and minutes:
        for label, calls, ms in re.findall(r"\| (\S+) \((\d+) calls\) " + DUR, line):
            minutes[-1][label] = (float(ms), int(calls))
    m = re.search(r"ai perf minute (\d+): AI time per tick \(average over \d+ ticks\) " + DUR, line)
    if m: ai_tick[int(m.group(1))] = float(m.group(2))
    m = re.search(r"ai perf minute (\d+): \d+ ticks, \d+ AI runs, AI time " + DUR + r" \| wall clock " + DUR, line)
    if m: wall[int(m.group(1))] = float(m.group(3)) / 1000
    m = re.search(r"ai perf minute (\d+) parts (.*)", line)
    if m: parts[int(m.group(1))] = {k: float(v) for k, v in re.findall(r"\| (\S+) " + DUR, m.group(2))}
    if "[rts] sched:" in line:
        sched.append(re.sub(r"^ *[0-9.]+ Script @__factorio-rts__/[^ ]+ ", "", line.rstrip()))
if not minutes:
    print("no '[rts] perf tick' lines (run with PERF=1)"); sys.exit(1)
last = last or len(minutes)
sel = minutes[first - 1:last]
labels = sorted({l for m in sel for l in m})
def stats(label):
    xs = [m.get(label, (0.0, 0))[0] for m in sel]
    calls = sum(m.get(label, (0.0, 0))[1] for m in sel) / len(sel)
    return sum(xs) / len(xs), max(xs), calls
rows = sorted(((l,) + stats(l) for l in labels), key=lambda r: -r[1])
print(f"=== per module, ms per tick, perf minutes {first}..{last} of {len(minutes)} (mean of the minutes, worst minute) ===")
for l, mean, mx, calls in rows:
    if mean >= 0.0005 or mx >= 0.002:
        print(f"  {l:16s} mean {mean:7.4f}  worst minute {mx:7.4f}  calls/min {calls:8.0f}")
def group(names):
    per = [sum(v[0] for l, v in m.items() if names is None or l in names or (names == "ai" and l.startswith("ai/")))
           for m in sel]
    return sum(per) / len(per), max(per)
for name, g in (("all modules", None), ("AI (ai/*)", "ai"), ("M2 modules", M2), ("M3 modules", M3)):
    mean, mx = group(g)
    print(f"  = {name:14s} mean {mean:7.4f}  worst minute {mx:7.4f}")
if ai_tick:
    ks = [k for k in sorted(ai_tick) if (k >= first - 1 and (k <= last))] or sorted(ai_tick)
    xs = [ai_tick[k] for k in ks]
    print(f"=== AI commanders (ai/init profiler), AI minutes {ks[0]}..{ks[-1]}: mean {sum(xs)/len(xs):.3f} ms/tick, "
          f"worst minute {max(xs):.3f} (all nations together) ===")
    if parts:
        pk = [k for k in ks if k in parts]
        names = sorted({n for k in pk for n in parts[k]})
        print("  parts, ms per tick: " + ", ".join(
            f"{n} {sum(parts[k].get(n, 0) for k in pk) / len(pk) / 3600:.4f}" for n in names))
if wall:
    ks = [k for k in sorted(wall) if k >= first - 1 and k <= last] or sorted(wall)
    print("=== wall clock per game minute (s) and UPS: " + "  ".join(
        f"m{k} {wall[k]:.2f}s/{3600 / wall[k]:.1f}" for k in ks))
for s in sched[-12:]:
    print("  " + s[:300])
PY
