# r2-econ (0.1.1, #6): no-fuel waits of haulers from a server log; "remote" = not at the hub where the rule makes it
# wait (manual: the pickup; auto: home). Game minutes are interpolated from the "ai minute N" lines.
# Usage: python3 tools/probes/r2e_strand.py build/<run>-server.log [min_minutes=1]
import re, sys, collections
path = sys.argv[1]; thr = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
lines = open(path, errors="replace").read().splitlines()
mins = []
for ln in lines:
    m = re.match(r"\s*([\d.]+) .*\[rts\] ai minute (\d+) (\S+?):", ln)
    if m and (not mins or int(m.group(2)) > mins[-1][1]): mins.append((float(m.group(1)), int(m.group(2))))
def gm(w):
    prev = (0.0, 0)
    for wl, mm in mins:
        if w <= wl:
            a, b = prev
            return b + (w - a) / (wl - a) * (mm - b) if wl > a else mm
        prev = (wl, mm)
    return mins[-1][1] if mins else 0
H = collections.defaultdict(dict)
waits = []
open_w = {}
endw = None
for ln in lines:
    m = re.match(r"\s*([\d.]+) ", ln)
    if not m: continue
    w = float(m.group(1)); endw = w
    m = re.search(r"logistics: hauler #(\d+) of (\S+) spawned at .*, auto, home hub #(\S+)", ln)
    if m: H[m.group(1)].update(force=m.group(2), mode="auto", home=m.group(3), at=m.group(3)); continue
    m = re.search(r"logistics: hauler #(\d+) re-homed to hub #(\d+)", ln)
    if m: H[m.group(1)]["home"] = m.group(2); continue
    m = re.search(r"logistics: hauler #(\d+) route pickup hub #(\S+) -> drop-off hub #(\S+)", ln)
    if m: H[m.group(1)].update(pickup=m.group(2), dropoff=m.group(3)); continue
    m = re.search(r"logistics: hauler #(\d+) home hub #(\d+)", ln)
    if m: H[m.group(1)]["home"] = m.group(2); continue
    m = re.search(r"logistics: hauler #(\d+) returns home to hub #(\S+)", ln)
    if m: H[m.group(1)].update(home=m.group(2), mode="auto"); continue
    m = re.search(r"logistics: hauler #(\d+) mode (\w+) \(home #(\S+), pickup #(\S+), drop-off #(\S+)\)", ln)
    if m: H[m.group(1)].update(mode=m.group(2), home=m.group(3), pickup=m.group(4), dropoff=m.group(5)); continue
    m = re.search(r"logistics: hauler #(\d+) arrived at hub #(\d+)", ln)
    if m: H[m.group(1)]["at"] = m.group(2); continue
    m = re.search(r"logistics: hauler #(\d+) \((\S+), (\w+)\) (\w+)(?: \(([\w-]+)\))?$", ln)
    if m:
        un, force, mode, state, reason = m.groups()
        h = H[un]; h["force"] = force; h["mode"] = mode
        if un in open_w:
            s = open_w.pop(un); s["end"] = w; waits.append(s)
        if state == "waiting" and reason == "no-fuel":
            at = h.get("at")
            if mode == "manual": remote = at != h.get("pickup")
            else: remote = at != h.get("home")
            open_w[un] = dict(un=un, force=force, mode=mode, at=at, start=w, remote=remote,
                              role=("pickup" if at == h.get("pickup") else "dropoff" if at == h.get("dropoff") else "home" if at == h.get("home") else "other"))
    m = re.search(r"logistics: hauler lost #?(\d+)|hauler #(\d+) .*(destroyed|died|lost)", ln)
for un, s in open_w.items():
    s["end"] = endw; s["open"] = True; waits.append(s)
tot = collections.defaultdict(float)
rows = []
for s in waits:
    d = gm(s["end"]) - gm(s["start"])
    tot[(s["force"], s["mode"], "remote" if s["remote"] else "at-start")] += d
    if d >= thr: rows.append((d, s))
for d, s in sorted(rows, key=lambda r: -r[0]):
    print(f"  #{s['un']:>5} {s['force']:10} {s['mode']:6} at hub #{s['at']} ({s['role']}{', REMOTE' if s['remote'] else ''}) "
          f"from {gm(s['start']):5.1f} for {d:5.1f} min{' (still at the end)' if s.get('open') else ''}")
uniq = {}
for d, s2 in rows:
    if s2["remote"]: uniq[s2["un"]] = max(uniq.get(s2["un"], 0), d)
print(f"  haulers stranded >= {thr} min at a remote hub: {len(uniq)}", {k: round(v,1) for k,v in sorted(uniq.items(), key=lambda kv:-kv[1])})
print("  totals (game-min):", {"/".join(k): round(v, 1) for k, v in sorted(tot.items())})
