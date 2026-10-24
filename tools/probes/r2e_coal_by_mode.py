# r2-econ (0.1.1, #6/#7): hauler coal by mode from a server log: every arrival leg costs ceil(tiles * 1.1 / 40) coal (the Nation
# charge; legs inside one network are free and counted here too, so this is an upper bound), deliveries and items.
# Usage: python3 tools/probes/r2e_coal_by_mode.py build/<run>-server.log
import re, sys, math, collections
mode = {}; force = {}
coal = collections.Counter(); legs = collections.Counter(); dels = collections.Counter(); items = collections.Counter()
small = collections.Counter()
for ln in open(sys.argv[1], errors="replace"):
    m = re.search(r"logistics: hauler #(\d+) of (\S+) spawned", ln)
    if m: force[m.group(1)] = m.group(2); mode[m.group(1)] = "auto"; continue
    m = re.search(r"logistics: hauler #(\d+) \((\S+), (\w+)\)", ln)
    if m: force[m.group(1)] = m.group(2); mode[m.group(1)] = m.group(3); continue
    m = re.search(r"logistics: hauler #(\d+) arrived at hub #\d+ \(\w+\): ([\d.]+) tiles", ln)
    if m:
        k = (force.get(m.group(1), "?"), mode.get(m.group(1), "?"))
        coal[k] += math.ceil(float(m.group(2)) * 1.1 / 40); legs[k] += 1; continue
    m = re.search(r"logistics: hauler #(\d+) delivered (.*) to hub #\d+ \(trip", ln)
    if m:
        k = (force.get(m.group(1), "?"), mode.get(m.group(1), "?"))
        n = sum(int(x) for x in re.findall(r"(\d+) [\w-]+", m.group(2)))
        dels[k] += 1; items[k] += n; small[k] += n < 20
for k in sorted(legs):
    print(f"  {k[0]:10s} {k[1]:6s} legs {legs[k]:4d} coal {coal[k]:5d} deliveries {dels[k]:4d} items {items[k]:6d} "
          f"items/coal {items[k] / max(1, coal[k]):5.1f} under-20 deliveries {small[k]}")
