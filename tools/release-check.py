#!/usr/bin/env python3
"""REPORT.md of tools/release-check.sh: reads <rc dir>/info.env, runs.tsv, the stage outputs and the server logs in
build/, evaluates the acceptance criteria and prints the report (markdown) to stdout.
Usage: python3 -I tools/release-check.py build/release-check/<date> > build/release-check/<date>/REPORT.md
Targets come from the M3 contract (docs/PHASE5-M3.md section 4) and the open 0.1.1 issues (#1-#8); each row names its
source. A stage that did not run shows "not run"."""
import difflib
import os
import re
import sys

RC = os.path.abspath(sys.argv[1])
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD = os.path.join(ROOT, "build")
PFX = re.compile(r"^ *[0-9.]+ Script @[^ ]+ ")
ERR = re.compile(r"Error|rror while running|Exception|Unknown key|missing locale")


def env(name):
    out = {}
    path = os.path.join(RC, name)
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    return out


INFO, RUN, MX = env("info.env"), env("info-run.env"), env("matrix.env")
QUICK = bool(INFO.get("QUICK"))
RUNS = []  # (id, kind, run name, extra)
if os.path.exists(os.path.join(RC, "runs.tsv")):
    for line in open(os.path.join(RC, "runs.tsv")):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            RUNS.append((parts[0], parts[1], parts[2], parts[3] if len(parts) > 3 else ""))


def runs(kind):
    return [r for r in RUNS if r[1] == kind]


def text(path):
    return open(path, errors="replace").read() if os.path.exists(path) else ""


def rc_of(job_id):
    t = text(os.path.join(RC, job_id + ".rc")).strip()
    return int(t) if t.lstrip("-").isdigit() else None


def rts_lines(path):
    if not os.path.exists(path):
        return []
    return [PFX.sub("", l.rstrip("\n")) for l in open(path, errors="replace") if "[rts]" in l]


def errors_in(*paths):
    out = []
    for p in paths:
        if os.path.exists(p):
            for l in open(p, errors="replace"):
                if ERR.search(l) and "Got EOF on stdin" not in l:
                    out.append(os.path.basename(p) + ": " + l.strip()[:200])
    return out


def mins(t):
    m = re.match(r"(\d+):(\d+)$", t or "")
    return int(m.group(1)) + int(m.group(2)) / 60 if m else None


# ---------------------------------------------------------------- the acceptance probe logs (m3_acceptance.lua)
NAT_RE = re.compile(r"m3 acceptance nation (\S+): Age II (\S+), Age III (\S+), first line (\S+), lines open (\d+), "
                    r"items by train (\d+) \| balance now (-?\d+), lowest (-?\d+) at \S+, highest debt stage (\d)"
                    r"(?: at \S+)?, ([0-9.]+) min in debt, credit line (\S+), tax switches (\S*)")


def num(pat, s, default=None):
    m = re.search(pat, s)
    return int(m.group(1)) if m else default


def acceptance(run):
    log = os.path.join(BUILD, run + "-server.log")
    lines = rts_lines(log)
    a = {"run": run, "exists": bool(lines), "checks": {}, "nat": {}, "ai3": {}, "doctrine": {}, "walls": [],
         "summary": None, "last_minute": 0}
    for l in lines:
        m = re.match(r"\[rts\] (?:m3|ai) (?:acceptance|autotest) check (\S+): (PASS|FAIL) ?(.*)", l)
        if m:
            a["checks"][m.group(1)] = (m.group(2), m.group(3))
            continue
        m = NAT_RE.search(l)
        if m:
            g = m.groups()
            a["nat"][g[0]] = {"age2": g[1], "age3": g[2], "first_line": g[3], "items": int(g[5]), "lowest": int(g[7]),
                              "debt": int(g[8]), "credit": g[10]}
            continue
        m = re.match(r"\[rts\] ai minute (\d+) (\S+) ai3: (.*)", l)
        if m:
            minute, force, rest = int(m.group(1)), m.group(2), m.group(3)
            a["ai3"].setdefault(force, {})[minute] = {
                "cities": num(r"^cities (\d+)", rest), "linked": num(r"linked (\d+)", rest),
                "ops": num(r"\(started (\d+),", rest, 0), "holds": num(r"holds (\d+)", rest, 0),
                "belts": num(r"belts (\d+)", rest, 0), "patrols": num(r"air patrols (\d+)", rest, 0),
                "interceptors": num(r"interceptors (\d+)", rest, 0), "bombs": num(r"bombs (\d+)", rest, 0),
                "artillery": num(r"artillery (\d+)", rest, 0)}
            continue
        m = re.match(r"\[rts\] ai minute (\d+) (\S+) phase\d: doctrine (\w+)", l)
        if m:
            a["doctrine"].setdefault(m.group(2), {})[int(m.group(1))] = m.group(3)
            continue
        m = re.match(r"\[rts\] ai perf minute (\d+): .*wall clock Duration: ([0-9.]+)ms", l)
        if m:
            a["walls"].append((int(m.group(1)), float(m.group(2)) / 1000))
            continue
        m = re.match(r"\[rts\] ai minute (\d+) match:", l)
        if m:
            a["last_minute"] = max(a["last_minute"], int(m.group(1)))
        if "ai autotest summary" in l:
            a["summary"] = l.split("summary ", 1)[1]
    a["errors"] = errors_in(log, os.path.join(BUILD, run + "-create.log"))
    return a


def last_ai3(a, force, at=None):
    rows = a["ai3"].get(force, {})
    keys = sorted(k for k in rows if at is None or k <= at)
    return rows[keys[-1]] if keys else None


def doctrine_at(a, force, minute):
    rows = a["doctrine"].get(force, {})
    keys = sorted(k for k in rows if k <= minute)
    return rows[keys[-1]] if keys else None


def speed1(a, n=5):
    return [w for _, w in a["walls"][-n:]]


def seed_of(extra):
    m = re.search(r"seed=(\d+)", extra)
    return m.group(1) if m else "?"


# ---------------------------------------------------------------- report helpers
ROWS = []  # verdict rows: (stage, criterion, target, value, status, source)


def row(stage, criterion, target, value, ok, source=""):
    status = "PASS" if ok is True else ("FAIL" if ok is False else str(ok))
    ROWS.append((stage, criterion, target, value, status, source))


DETAIL = []


def out(s=""):
    DETAIL.append(s)


def frac(n, d):
    return f"{n} of {d}"


# ---------------------------------------------------------------- smoke
def stage_smoke():
    if not runs("smoke"):
        return
    t = text(os.path.join(RC, "smoke.txt"))
    m = re.search(r"autotest summary (\S+)", t)
    errs = [l for l in t.split("=== errors ===")[-1].splitlines()[1:] if l and not l.startswith("log:") and l != "(none)"] \
        if "=== errors ===" in t else ["no output"]
    row("smoke", "Skirmish smoke (legacy units, seed 9090)", "65/65, 0 errors",
        f"{m.group(1) if m else 'no summary'}, {len(errs)} errors", bool(m) and m.group(1) == "65/65" and not errs,
        "CONTRIBUTING")


# ---------------------------------------------------------------- matrix
STOP = re.compile(r"\[rts\] (ai )?autotest summary")
MPFX = re.compile(r"^ *[0-9.]+ Script @__factorio-rts__/[^ ]+ ")
TIMING = re.compile(r"perf|wall clock| ms\b|ms/tick|ms per|took [0-9.]+ ?ms|elapsed|real time|UPS", re.I)
NORMALISE = [(re.compile(r"Duration: [0-9.]+ ?[a-z]*"), "Duration: T"),
             (re.compile(r"[0-9]+ rts technologies"), "N rts technologies"),
             (re.compile(r"rts-garrison-turret "), ""), (re.compile(r"rts-(bomber|interceptor|aa-turret) "), "")]


def mx_lines(path):
    out_ = []
    if not os.path.exists(path):
        return None
    for line in open(path, errors="replace"):
        if "[rts]" not in line:
            continue
        line = MPFX.sub("", line.rstrip("\n"))
        for rx, rep in NORMALISE:
            line = rx.sub(rep, line)
        if TIMING.search(line):
            continue
        out_.append(line)
        if STOP.search(line):
            break
    return out_


def line_class(l):
    w = re.sub(r"^\[rts\] ", "", l).split(" ", 1)[0].rstrip(":").lower()
    return re.sub(r"\d+", "N", w)


def stage_matrix():
    if not MX:
        return
    base, head = MX.get("MATRIX_BASE"), MX.get("MATRIX_HEAD")
    gui = set(RUN.get("GUI_CLASSES", "").split())
    scen = MX.get("MATRIX_SCENARIOS", "").split()
    out("## Skirmish matrix (seed 777)")
    out()
    note = ""
    if MX.get("MATRIX_BASE_WANTED") and MX.get("MATRIX_BASE_WANTED") != base:
        note = (f" The requested baseline `{MX['MATRIX_BASE_WANTED']}` has no server logs left in `build/`, so the "
                f"baseline is `{base}`: the matrix of {MX.get('MATRIX_BASE_REV', 'the base revision')}, run once with the "
                f"same seed and kept in `build/` for later checks.")
    out(f"Tree `{head}` against the baseline `{base}`, compared line by line with `tools/matrix-compare.sh`'s "
        f"normalisation.{note} Differing lines are grouped by class (their first word); the GUI classes "
        f"({', '.join(sorted(gui))}) may differ.")
    out()
    out("| Scenario | Baseline summary | Tree summary | Lines | Differing | Differing classes | Result |")
    out("|---|---|---|---|---|---|---|")
    bad, total_diff, gui_only = 0, 0, {}
    summaries = {}
    for s in scen:
        a = mx_lines(os.path.join(BUILD, f"mx-{base}-{s}-server.log"))
        b = mx_lines(os.path.join(BUILD, f"mx-{head}-{s}-server.log"))
        def summ(lines):
            if lines is None:
                return "missing"
            x = [l for l in lines if "autotest summary" in l]
            return x[-1].split("summary ", 1)[1].split(",")[0] if x else "no summary"
        sa, sb = summ(a), summ(b)
        summaries[s] = sb
        if a is None or b is None:
            out(f"| {s} | {sa} | {sb} | - | - | - | FAIL (log missing) |")
            bad += 1
            continue
        sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
        classes = {}
        nd = 0
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op == "equal":
                continue
            nd += max(i2 - i1, j2 - j1)
            for l in a[i1:i2] + b[j1:j2]:
                c = line_class(l)
                classes[c] = classes.get(c, 0) + 1
        other = {c: n for c, n in classes.items() if c not in gui}
        for c, n in classes.items():
            if c in gui:
                gui_only[c] = gui_only.get(c, 0) + n
        total_diff += nd
        ok = not other
        bad += 0 if ok else 1
        cl = ", ".join(f"{c} {n}" + ("" if c in gui else " (not GUI)") for c, n in sorted(classes.items(), key=lambda x: -x[1])[:6])
        out(f"| {s} | {sa} | {sb} | {len(a)} / {len(b)} | {nd} | {cl or '-'} | {'PASS' if ok else 'FAIL'} |")
    out()
    errs = []
    for s in scen:
        errs += errors_in(os.path.join(BUILD, f"mx-{head}-{s}-server.log"), os.path.join(BUILD, f"mx-{head}-{s}-create.log"))
    out(f"Lua errors in the tree's matrix runs: {len(errs)}." + (" First: " + errs[0] if errs else ""))
    out()
    row("matrix", f"Skirmish identity, {len(scen)} scenario{'' if len(scen) == 1 else 's'} against `{base}`", "0 differing lines outside GUI classes",
        f"{total_diff} differing lines; GUI-only classes: {', '.join(f'{c} {n}' for c, n in gui_only.items()) or 'none'}",
        bad == 0, "CONTRIBUTING, M3 notes 9.1")
    row("matrix", "Lua errors in the matrix", "0", str(len(errs)), not errs)


# ---------------------------------------------------------------- acceptance sets (801-805, 701-705, 3072)
def acc_table(title, accs):
    out(f"## {title}")
    out()
    out("| Seed | AI autotest | Trade / war / peace / capture | Starving | Debt (stage) | Credit line | Lowest ₡ | "
        "First Age III | Cities ≥ 3 | Linked by 35:00 | Aggressive first line | Ops / belts / air patrols / interceptors+bombs / artillery / holds | Speed-1 minutes (s) | Errors |")
    out("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for seed, a in accs:
        if not a["exists"]:
            out(f"| {seed} | no log | | | | | | | | | | | | |")
            continue
        c = a["checks"]
        m2 = "/".join(c.get(k, ("-",))[0][0] if c.get(k) else "-" for k in ("trade", "war", "peace", "capture"))
        nat = a["nat"]
        debt = ", ".join(f"{f.replace('rts-', '')} ({v['debt']})" for f, v in nat.items() if v["debt"] >= 1) or "none"
        credit = ", ".join(f.replace("rts-", "") for f, v in nat.items() if v["credit"] != "never") or "none"
        low = min((v["lowest"] for v in nat.values()), default=None)
        a3 = sorted((v["age3"] for v in nat.values() if mins(v["age3"]) is not None), key=mins)
        forces = sorted(set(nat) | set(a["ai3"]))
        cities = sum(1 for f in forces if (last_ai3(a, f) or {}).get("cities") is not None and last_ai3(a, f)["cities"] >= 3)
        linked = sum(1 for f in forces if (last_ai3(a, f, 35) or {}).get("linked") is not None
                     and a["ai3"][f].get(35) is not None and a["ai3"][f][35]["linked"] >= 3)
        aggr = [f for f in forces if doctrine_at(a, f, 30) == "aggressive"]
        aggr_s = ", ".join(f"{f.replace('rts-', '')} {nat.get(f, {}).get('first_line', '-')}" for f in aggr) or "none"
        tot = lambda k: sum((last_ai3(a, f) or {}).get(k, 0) or 0 for f in forces)
        ops = sum(1 for f in forces if ((last_ai3(a, f) or {}).get("ops") or 0) >= 1)
        walls = " ".join(f"{w:.1f}" for w in speed1(a))
        out(f"| {seed} | {(a['summary'] or '-').split(',')[0]} | {m2} | {c.get('starving', ('-',))[0]} | {debt} | {credit} | "
            f"{low if low is not None else '-'} | {a3[0] if a3 else 'none'} | {cities} of {len(forces)} | {linked} of {len(forces)} | "
            f"{aggr_s} | {ops}/{len(forces)} nations, {tot('belts')} / {tot('patrols')} / {tot('interceptors') + tot('bombs')} / "
            f"{tot('artillery')} / {tot('holds')} | {walls or '-'} | {len(a['errors'])} |")
    out()


def acc_rows(stage, accs, full):
    present = [(s, a) for s, a in accs if a["exists"]]
    n = len(present)
    if not n:
        row(stage, "acceptance runs", f"{len(accs)} logs", "no log", False)
        return
    def seeds(pred):
        return sum(1 for _, a in present if pred(a))
    def forces(a):
        return sorted(set(a["nat"]) | set(a["ai3"]))
    m2ok = seeds(lambda a: all(a["checks"].get(k, ("FAIL",))[0] == "PASS" for k in ("trade", "war", "peace", "capture")))
    row(stage, "M2 criteria: trade, war, peace, capture", f"{n} of {n} seeds", frac(m2ok, n), m2ok == n, "M2/M3 contract")
    starv = seeds(lambda a: a["checks"].get("starving", ("PASS",))[0] == "FAIL")
    row(stage, "Seeds with a starving nation", "at most 1", str(starv), starv <= 1, "M2 tolerance")
    errs = sum(len(a["errors"]) for _, a in present)
    row(stage, "Lua errors", "0", str(errs), errs == 0, "contract")
    walls = [w for _, a in present for w in speed1(a)]
    slow = [w for w in walls if w > 60.5]
    row(stage, "Speed-1 minutes (last 5 of each run)", "≤ 60.5 s each (60 UPS)",
        f"{len(walls)} minutes, max {max(walls):.1f} s" if walls else "no wall-clock lines", bool(walls) and not slow, "contract")
    if not full:
        return
    nations = [(a, f) for _, a in present for f in forces(a)]
    nn = len(nations)
    a3 = seeds(lambda a: any((mins(v["age3"]) or 99) <= 40 for v in a["nat"].values()))
    row(stage, "Age III by 40:00", f"≥ 3 of 5 seeds", frac(a3, n), a3 >= 3 if n >= 5 else f"{frac(a3, n)} (needs 5 seeds)", "#1, M3 contract")
    linked = sum(1 for a, f in nations if a["ai3"].get(f, {}).get(35) and a["ai3"][f][35]["linked"] >= 3)
    row(stage, "Nations with 3 cities linked by rail by 35:00", "≥ 16 of 20", frac(linked, nn),
        linked >= 16 if nn >= 20 else f"{frac(linked, nn)} (needs 20 nations)", "#2")
    def aggr_ok(a):
        ag = [f for f in forces(a) if doctrine_at(a, f, 30) == "aggressive"]
        return bool(ag) and all((mins(a["nat"].get(f, {}).get("first_line")) or 99) < 32 for f in ag)
    ag_seeds = seeds(lambda a: any(doctrine_at(a, f, 30) == "aggressive" for f in forces(a)))
    ag = seeds(aggr_ok)
    row(stage, "Aggressive AI's first rail line before 32:00", "≥ 4 of 5 seeds", f"{ag} of {ag_seeds} seeds with an aggressive AI",
        ag >= 4 if n >= 5 else f"{ag} of {ag_seeds} (needs 5 seeds)", "#2")
    def alive(a, f):  # a nation still reporting at the run's last AI minute
        last = max((m for rows in a["ai3"].values() for m in rows), default=None)
        return last is not None and last in a["ai3"].get(f, {})
    living = [(a, f) for a, f in nations if alive(a, f)]
    cities = sum(1 for a, f in living if ((last_ai3(a, f) or {}).get("cities") or 0) >= 3)
    row(stage, "Nations alive at the end with ≥ 3 cities", "every nation alive", f"{cities} of {len(living)} alive ({nn - len(living)} conquered)",
        bool(living) and cities == len(living), "M3 contract")
    ops = sum(1 for a, f in nations if ((last_ai3(a, f) or {}).get("ops") or 0) >= 1)
    row(stage, "Nations that ran an operation with phases", "every nation", frac(ops, nn), ops == nn, "M3 contract")
    tot = lambda a, k: sum((last_ai3(a, f) or {}).get(k, 0) or 0 for f in forces(a))
    belts = seeds(lambda a: tot(a, "belts") > 0)
    row(stage, "Seeds with a fort belt built", f"{n} of {n}", frac(belts, n), belts == n, "M3 contract")
    patrols = seeds(lambda a: tot(a, "patrols") > 0)
    row(stage, "Seeds with air patrols", "≥ 3 of 5", frac(patrols, n), patrols >= 3 if n >= 5 else frac(patrols, n), "M3 notes 4.2")
    strike = seeds(lambda a: tot(a, "interceptors") + tot(a, "bombs") > 0)
    row(stage, "Seeds with an interceptor patrol or a bomber strike", "≥ 3 of 5", frac(strike, n), strike >= 3 if n >= 5 else frac(strike, n), "#4")
    art = seeds(lambda a: tot(a, "artillery") > 0)
    row(stage, "Seeds with an artillery train bombarding", "≥ 2 of 5", frac(art, n), art >= 2 if n >= 5 else frac(art, n), "#4")
    debt = seeds(lambda a: any(v["debt"] >= 1 for v in a["nat"].values()))
    row(stage, "Seeds with a nation in a debt stage", "≥ 2 of 5", frac(debt, n), debt >= 2 if n >= 5 else frac(debt, n), "M3 money target, #5")
    bank = sum(1 for _, a in present for v in a["nat"].values() if v["credit"] != "never")
    row(stage, "Nations at the credit line (bankrupt)", "0", str(bank), bank == 0, "#5")


def stage_acceptance():
    for kind, title, full in (("m3", "M3 end-to-end: seeds 801-805 (4 normal AIs, 2048, 60 min)", True),
                              ("m2", "M2 acceptance: seeds 701-705 (the same fixture)", False)):
        rs = runs(kind)
        if not rs:
            continue
        accs = [(seed_of(r[3]), acceptance(r[2])) for r in rs]
        acc_table(title, accs)
        acc_rows(kind, accs, full)
    rs = runs("w3072")
    if rs:
        accs = [(seed_of(r[3]), acceptance(r[2])) for r in rs]
        acc_table("3072 x 4 world (holds, air, artillery)", accs)
        acc_rows("w3072", accs, False)
        a = accs[0][1]
        if a["exists"]:
            forces = sorted(set(a["nat"]) | set(a["ai3"]))
            tot = lambda k: sum((last_ai3(a, f) or {}).get(k, 0) or 0 for f in forces)
            row("w3072", "Front holds", "> 0", str(tot("holds")), tot("holds") > 0, "#4")
            air = tot("patrols") + tot("interceptors") + tot("bombs")
            row("w3072", "Air: patrols + interceptor patrols + bomber strikes", "> 0", str(air), air > 0, "#4")
            row("w3072", "Artillery train bombardments", "> 0", str(tot("artillery")), tot("artillery") > 0, "#4")


# ---------------------------------------------------------------- M1 twice
RUNCMP_TIMING = re.compile(r"perf|wall clock| ms\b|ms/tick|ms per|took [0-9.]+ ?ms|elapsed|real time|UPS|game speed|"
                           r"done in [0-9.]+ s|after [0-9.]+ s", re.I)


def runcmp_lines(path):
    res = []
    if not os.path.exists(path):
        return None
    for line in open(path, errors="replace"):
        if "[rts]" not in line:
            continue
        line = MPFX.sub("", line.rstrip("\n"))
        line = re.sub(r"Duration: [0-9.]+ ?[a-z]*", "Duration: T", line)
        if RUNCMP_TIMING.search(line):
            continue
        res.append(line)
        if STOP.search(line):
            break
    return res


def stage_m1():
    rs = runs("m1")
    if not rs:
        return
    out("## M1 acceptance: seed 501 twice (1v1, 2048, 60 min)")
    out()
    out("| Run | AI autotest | Failed checks | Train items | Errors |")
    out("|---|---|---|---|---|")
    accs = []
    for r in rs:
        a = acceptance(r[2])
        accs.append(a)
        failed = [k for k, v in a["checks"].items() if v[0] == "FAIL"]
        ti = a["checks"].get("train_items", ("-", ""))[1]
        m = re.match(r"(\d+) items", ti)
        a["train_items"] = int(m.group(1)) if m else None
        out(f"| {r[3]} | {(a['summary'] or '-').split(',')[0]} | {', '.join(failed) or 'none'} | "
            f"{a['train_items'] if a['train_items'] is not None else '-'} | {len(a['errors'])} |")
    out()
    if len(rs) >= 2:
        la, lb = runcmp_lines(os.path.join(BUILD, rs[0][2] + "-server.log")), runcmp_lines(os.path.join(BUILD, rs[1][2] + "-server.log"))
        if la is not None and lb is not None:
            sm = difflib.SequenceMatcher(None, la, lb, autojunk=False)
            nd = sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in sm.get_opcodes() if op != "equal")
            out(f"The two runs: {len(la)} and {len(lb)} `[rts]` lines, {nd} differing.")
            out()
            row("m1", "Two runs line-identical (SPEED 8 and 10)", "0 differing lines", f"{nd} of {len(la)}", nd == 0 and len(la) > 0, "M3 notes 9.2")
    a = accs[0]
    summ = (a["summary"] or "no summary").split(",")[0]
    row("m1", "M1 acceptance score", "all checks pass", summ, "(all passed)" in (a["summary"] or ""), "M1 contract")
    ti = [x["train_items"] for x in accs if x.get("train_items") is not None]
    row("m1", "Items moved by train", "≥ 20,000 in both runs", ", ".join(f"{x:,}" for x in ti) or "-",
        bool(ti) and min(ti) >= 20000, "#7")
    errs = sum(len(x["errors"]) for x in accs)
    row("m1", "Lua errors", "0", str(errs), errs == 0)
    walls = [w for x in accs for w in speed1(x)]
    row("m1", "Speed-1 minutes (last 5 of each run)", "≤ 60.5 s each (60 UPS)",
        f"{len(walls)} minutes, max {max(walls):.1f} s" if walls else "no wall-clock lines", bool(walls) and max(walls) <= 60.5, "M1 contract")


# ---------------------------------------------------------------- save/load
def stage_sl():
    rs = runs("sl")
    if not rs:
        return
    out("## Save and load (seed 802, 4 nations)")
    out()
    out("| Save at minute | Errors before the save | Errors after the load | Last minute after the load | Result |")
    out("|---|---|---|---|---|")
    last_lines = {}
    all_ok = True
    for r in sorted(rs, key=lambda r: int(re.search(r"minute=(\d+)", r[3]).group(1))):
        t = text(os.path.join(RC, r[0] + ".txt"))
        before = t.split("=== loading")[0].split("=== errors ===")[-1] if "=== errors ===" in t else "missing"
        e1 = [l for l in before.splitlines()[1:] if l.strip() and l.strip() != "(none)" and not l.startswith("log:")]
        saved = "did not save" not in t and "=== loading" in t
        after = t.split("=== errors after the load ===")[-1] if "=== errors after the load ===" in t else None
        e2 = [l for l in (after or "").splitlines()[1:] if l.strip() and l.strip() != "(none)" and not l.startswith("log:")]
        loaded = os.path.join(BUILD, r[2] + "-loaded-server.log")
        lines = rts_lines(loaded)
        mm = [int(m.group(1)) for l in lines for m in [re.match(r"\[rts\] ai minute (\d+) match", l)] if m]
        last = max(mm) if mm else None
        if last is not None:
            lp = [l for l in lines if re.match(rf"\[rts\] ai minute {last} rts-player:", l)]
            last_lines[r[0]] = (last, lp[-1] if lp else "")
        ok = saved and after is not None and not e1 and not e2 and last is not None
        all_ok &= ok
        out(f"| {re.search(r'minute=(\d+)', r[3]).group(1)} | {len(e1)} | {len(e2) if after is not None else 'no load'} | "
            f"{last if last is not None else '-'} | {'PASS' if ok else 'FAIL'} |")
    out()
    row("sl", "Save and load at minutes " + " and ".join(sorted((re.search(r"minute=(\d+)", r[3]).group(1) for r in rs), key=int)),
        "0 errors in every half, the game runs on", "see table", all_ok, "M3 contract")
    if len(last_lines) >= 2:
        vals = list(last_lines.values())
        common = min(v[0] for v in vals)
        same = None
        lines_at = []
        for r in rs:
            ls = [l for l in rts_lines(os.path.join(BUILD, r[2] + "-loaded-server.log"))
                  if re.match(rf"\[rts\] ai minute {common} rts-player:", l)]
            lines_at.append(ls[-1] if ls else None)
        same = all(x is not None and x == lines_at[0] for x in lines_at)
        out(f"Both loaded games at minute {common}: the rts-player report line is {'identical' if same else 'different'}.")
        out()
        row("sl", f"Both loaded games reach the same state (minute {common})", "identical rts-player line",
            "identical" if same else "different", same, "M3 notes 9.1")


# ---------------------------------------------------------------- determinism
def stage_det():
    rs = runs("det")
    if not rs:
        return
    vals = []
    for r in rs:
        t = text(os.path.join(RC, r[0] + ".txt"))
        m = re.search(r"=== (\w+) lines: run a (\d+), run b (\d+), differing (\d+) ===", t)
        vals.append((seed_of(r[3]), m.groups() if m else None))
    ok = all(v and int(v[3]) == 0 and int(v[1]) > 0 for _, v in vals)
    row("det", "Determinism: two runs per seed, event lines", "0 differing",
        "; ".join(f"{s}: {v[1]} / {v[2]} lines, {v[3]} differing" if v else f"{s}: no result" for s, v in vals), ok, "M3 contract")


# ---------------------------------------------------------------- perf scene
def stage_scene():
    if not runs("scene"):
        return
    t = text(os.path.join(RC, "scene.txt"))
    load = env("scene-load.env")
    out("## Perf scene (4 nations, 16 cities, 600 units, 40 trains)")
    out()
    m = re.search(r"wholeUpdate\s+mean\s+([0-9.]+)\s+p50\s+([0-9.]+)\s+p95\s+([0-9.]+)\s+p99\s+([0-9.]+)\s+max\s+([0-9.]+)", t)
    ups = re.search(r"UPS capacity at the mean tick: (\d+)", t)
    over = re.search(r"ticks over 16.67 ms whole: (\d+); ticks over 3 ms script: (\d+)", t)
    walls = [float(x) / 1000 for x in re.findall(r"perf scene minute \d+: .*wall clock Duration: ([0-9.]+)ms", t)]
    under = int(load.get("SCENE_OTHERS_AT_START", "0") or 0) > 0 or int(load.get("SCENE_OTHERS_AT_END", "0") or 0) > 0
    out(f"Machine: {load.get('SCENE_OTHERS_AT_START', '?')} other Factorio processes at the start and "
        f"{load.get('SCENE_OTHERS_AT_END', '?')} at the end (waited {load.get('SCENE_WAITED_S', '?')} s)."
        + (" **The bench ran under load: read the times as upper bounds.**" if under else ""))
    out()
    if m:
        out(f"wholeUpdate mean {m.group(1)} ms, p95 {m.group(3)}, p99 {m.group(4)}, max {m.group(5)}; UPS capacity "
            f"{ups.group(1) if ups else '-'}; ticks over 16.67 ms: {over.group(1) if over else '-'}; script ticks over "
            f"3 ms: {over.group(2) if over else '-'}.")
        out()
    fixture = ("nth60 ai/autotest", "nth60 perf_scene")
    marks = []  # "script > 3 ms ticks by marks": ticks whose script time is over 3 ms, per mark that ran in them
    if "=== script > 3 ms ticks by marks" in t:
        for l in t.split("=== script > 3 ms ticks by marks")[1].split("\n===")[0].splitlines()[1:]:
            mm = re.match(r"\s+(\d+)\s+([0-9.]+)\s+([0-9.]+)\s+(.+?)\s*$", l)
            if mm:
                marks.append((mm.group(4), int(mm.group(1)), float(mm.group(3))))
    slow = [(k, n, w) for k, n, w in marks if k not in fixture]
    # the literal #8 count: script ticks over 3 ms in the per-tick CSV, the autotest minute-report ticks (every 3,600th
    # benchmark tick, t % 3600 == 3599) left out
    literal = None
    csv = os.path.join(BUILD, runs("scene")[0][2] + "-out", "bench.out")
    if os.path.exists(csv):
        hdr, literal = None, 0
        for line in open(csv, errors="replace"):
            if line.startswith("tick,"):
                hdr = line.strip().strip(",").split(",")
            elif hdr and line.startswith("t") and line[1:2].isdigit():
                v = line.strip().strip(",").split(",")
                if int(v[0][1:]) % 3600 != 3599 and int(v[hdr.index("scriptUpdate")]) / 1e6 > 3:
                    literal += 1
    if marks:
        out("Script ticks over 3 ms by the marks that ran in them (the test fixtures' ai/autotest minute reports and "
            "perf_scene left out): " + (", ".join(f"{k} {n} (worst {w:.2f} ms)" for k, n, w in slow) or "none") + ".")
        out()
    row("scene", "Perf scene at speed 1 (realtime minutes)", "≤ 60.5 s per game minute",
        ", ".join(f"{w:.1f}" for w in walls) or "no realtime lines", bool(walls) and max(walls) <= 60.5, "M3 contract D9")
    if m:
        row("scene", "Mean tick / p99 / UPS capacity", "mean ≤ 16.67 ms (reference 2.1: 1.435, p99 5.68, 697)",
            f"{m.group(1)} / {m.group(4)} ms / {ups.group(1) if ups else '-'}" + (" (under load)" if under else ""),
            float(m.group(1)) <= 16.67, "M3 notes 9.1")
    else:
        row("scene", "Perf scene output", "a benchmark", "no benchmark output", False)
    if marks:
        mk = [x for x in marks if x[0] == "market.ai_step"]
        n_mk = mk[0][1] if mk else 0
        row("scene", "Script ticks over 3 ms with market.ai_step", "0", str(n_mk) + (f" (worst {mk[0][2]:.2f} ms)" if mk else ""),
            (n_mk == 0) if not under else f"{n_mk} (under load)", "#8 (title)")
    if literal is not None:
        row("scene", "Script ticks over 3 ms, minute-report ticks left out", "0", str(literal),
            (literal == 0) if not under else f"{literal} (under load)", "#8 (acceptance text)")
    if marks:
        row("scene", "Marks in script ticks over 3 ms", "informational",
            ", ".join(f"{k} {n}" for k, n, _ in slow[:8]) or "none", "info", "D9")


# ---------------------------------------------------------------- GUI stages
def stage_gui():
    for kind, label, pat in (("heavy", "Heavy mode (GUI client, 10 minutes)", r"heavy mode: (PASS|FAIL)"),
                             ("lan", "LAN: server and two GUI clients", r"lan check: (PASS|FAIL)")):
        if runs(kind):
            m = re.search(pat, text(os.path.join(RC, kind + ".txt")))
            row(kind, label, "PASS, 0 desyncs", m.group(1) if m else "no result", bool(m) and m.group(1) == "PASS", "M3 contract")


# ---------------------------------------------------------------- the report
stage_smoke()
stage_matrix()
stage_m1()
stage_acceptance()
stage_sl()
stage_det()
stage_scene()
stage_gui()

ran = sorted(set(r[1] for r in RUNS) | ({"matrix"} if MX else set()))
fails = [r for r in ROWS if r[4] == "FAIL"]
passes = [r for r in ROWS if r[4] == "PASS"]
infos = [r for r in ROWS if r[4] == "info"]
unjudged = [r for r in ROWS if r[4] not in ("PASS", "FAIL", "info")]
print(f"# Release check {os.path.basename(RC)}")
print()
print(f"Tree: `{INFO.get('REV', '?')}` = {INFO.get('REV_HASH', '?')} ({INFO.get('REV_SUBJECT', '')}), mod version "
      f"{INFO.get('MOD_VERSION', '?')}, {INFO.get('FACTORIO', '?')}. Started {INFO.get('STARTED', '?')}, finished "
      f"{RUN.get('FINISHED', '(running)')}; servers {RUN.get('SERVERS', '?')}; stages run: {', '.join(ran) or 'none'}.")
if INFO.get("UNCOMMITTED_MODS", "0") not in ("", "0"):
    print(f"The working tree had {INFO['UNCOMMITTED_MODS']} uncommitted changes under `mods/`; they are not part of "
          f"this check, which runs a `git archive` copy of the revision.")
if QUICK:
    print()
    print("**QUICK dry run:** short matches (6 minutes), one seed per set and two matrix scenarios. It proves that the "
          "script and its parsers work; the criteria below are not meaningful.")
print()
verdict = "FAIL" if fails else ("PASS" if not unjudged else "NOT JUDGED")
print(f"**{verdict}**: {len(passes)} criteria pass, {len(fails)} fail, {len(unjudged)} not judged (too few seeds or a "
      f"bench under load), {len(infos)} informational.")
print()
print("| Stage | Criterion | Target | Measured | Result | Source |")
print("|---|---|---|---|---|---|")
for st, cr, tg, val, status, src in ROWS:
    print(f"| {st} | {cr} | {tg} | {val} | {status} | {src} |")
print()
print("\n".join(DETAIL))
print("## Not covered by this script")
print()
print("- **GUI pass in English and Russian** and the **Codex GUI QA protocol** (`docs/qa/phase5-m3-protocol.md`): "
      "they need the screen and a tester.")
if not runs("lan") or not runs("heavy"):
    print("- **LAN and heavy mode** open GUI clients and need Steam: run `STAGES=\"lan heavy\" RC_DIR=" +
          os.path.relpath(RC, ROOT) + " tools/release-check.sh` when the screen is free; the report is rebuilt with them.")
print("- Hard against normal in swapped 1v1 matches (#3) has its own method in `docs/qa/phase5-ai3-notes.md`.")
print()
print("## Logs")
print()
print(f"Stage outputs: `{os.path.relpath(RC, ROOT)}/<stage>.txt`; server logs: `build/<run>-server.log` with these runs:")
print()
for r in RUNS:
    print(f"- `{r[0]}`: `{r[2]}` {r[3]}")
