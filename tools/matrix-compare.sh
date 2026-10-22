#!/usr/bin/env bash
# Compare two Skirmish matrix runs (tools/autotest-matrix.sh) line by line: every "[rts]" line of each scenario's
# server log up to its stop marker, with the timestamp prefix stripped, run-time durations and the number of defined
# technologies normalised, and timing-only lines (perf, wall clock, ms) dropped. Prints one row per scenario with the number of lines compared and the number that differ, and the first
# differing lines of each scenario that differs.
# Usage: tools/matrix-compare.sh <tag-a> <tag-b> [max-diff-lines=6]
#   SEED=777 tools/autotest-matrix.sh base && SEED=777 tools/autotest-matrix.sh wt && tools/matrix-compare.sh base wt
set -uo pipefail
cd "$(dirname "$0")/.."
A="${1:?tag a}"; B="${2:?tag b}"; MAXD="${3:-6}"
python3 - "$A" "$B" "$MAXD" <<'PY'
import glob, os, re, sys, difflib
a, b, maxd = sys.argv[1], sys.argv[2], int(sys.argv[3])
STOP = re.compile(r"\[rts\] (ai )?autotest summary")
PREFIX = re.compile(r"^ *[0-9.]+ Script @__factorio-rts__/[^ ]+ ")
TIMING = re.compile(r"perf|wall clock| ms\b|ms/tick|ms per|took [0-9.]+ ?ms|elapsed|real time|UPS", re.I)
# static differences that do not change play: run-time durations, the count of (Nation-only) technologies defined,
# Nation-only prototypes in derived lists
NORMALISE = [(re.compile(r"Duration: [0-9.]+ ?[a-z]*"), "Duration: T"),
             (re.compile(r"[0-9]+ rts technologies"), "N rts technologies"),
             (re.compile(r"rts-garrison-turret "), ""),  # M2 war's hidden gun in the derived turret list
             (re.compile(r"rts-(bomber|interceptor|aa-turret) "), "")]  # M3 air's Nation-only planes and AA turret
def lines(path):
    out = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if "[rts]" not in line: continue
                line = PREFIX.sub("", line.rstrip("\n"))
                for rx, rep in NORMALISE: line = rx.sub(rep, line)
                if TIMING.search(line): continue
                out.append(line)
                if STOP.search(line): break
    except FileNotFoundError:
        return None
    return out
names = sorted({os.path.basename(p)[len("mx-%s-" % a):-len("-server.log")]
                for p in glob.glob("build/mx-%s-*-server.log" % a)})
total_diff = 0
for n in names:
    la, lb = lines("build/mx-%s-%s-server.log" % (a, n)), lines("build/mx-%s-%s-server.log" % (b, n))
    if la is None or lb is None:
        print("%-28s missing log" % n); continue
    sm = difflib.SequenceMatcher(None, la, lb, autojunk=False)
    diff = [op for op in sm.get_opcodes() if op[0] != "equal"]
    nd = sum(max(i2 - i1, j2 - j1) for _, i1, i2, j1, j2 in diff)
    total_diff += nd
    print("%-28s %5d / %5d lines, %d differ" % (n, len(la), len(lb), nd))
    shown = 0
    for tag, i1, i2, j1, j2 in diff:
        for x in la[i1:i2][:2]: print("    - " + x[:200])
        for x in lb[j1:j2][:2]: print("    + " + x[:200])
        shown += 1
        if shown >= maxd: break
print("total differing lines: %d" % total_diff)
PY
