#!/usr/bin/env python3
"""Static check of the help cards (issue #30): every entry of ENTRIES in scripts/help.lua has a "how" and a "tip" text
in locale/en/help.cfg and locale/ru/help.cfg ([rts-help] section), both locales have the same keys, no text is empty,
and every entity name in the cfg is an entry. The other half of the check (every visible rts-* entity has an entry) runs
in the game: "[rts] help: N entries, 0 entities without help text" in the log at init.
Release 0.1.3 (#36): no locale value of any file names a release number ("0.1.1"), an issue number ("#22"), a phase or
milestone ("Phase 5", "M2") or an agent branch ("r4-hud"): a player never saw those.
Usage: help-check.py [mod dir]   (default mods/factorio-rts); exit 1 on a problem."""
import os, re, sys
mod = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "mods", "factorio-rts")
src = open(os.path.join(mod, "scripts", "help.lua"), encoding="utf-8").read()
entries = dict(re.findall(r'^\s*\["([^"]+)"\] = "([a-z]+)",\s*$', src, re.M))
problems = []
keys = {}
for lang in ("en", "ru"):
    sec, d = "", {}
    for line in open(os.path.join(mod, "locale", lang, "help.cfg"), encoding="utf-8"):
        s = line.rstrip("\n")
        if not s.strip() or s.startswith("#"): continue
        m = re.match(r"^\[(.*)\]$", s)
        if m: sec = m.group(1); continue
        if "=" in s and sec == "rts-help":
            k, v = s.split("=", 1)
            d[k] = v
            if not v.strip(): problems.append("%s: empty text for %s" % (lang, k))
    keys[lang] = d
    for name in entries:
        for suffix in (("how", "tip", "line") if entries[name] == "piece" else ("how", "tip")):
            if "%s-%s" % (name, suffix) not in d: problems.append("%s: missing %s-%s" % (lang, name, suffix))
    for k in d:
        m = re.match(r"^(.*)-(how|tip|line)$", k)
        if m and not k.startswith("card-") and m.group(1) not in entries: problems.append("%s: %s has no entry in help.lua" % (lang, k))
if set(keys["en"]) != set(keys["ru"]):
    problems.append("en/ru keys differ: %s" % sorted(set(keys["en"]) ^ set(keys["ru"])))
FORBIDDEN = [(re.compile(r"\b\d+\.\d+\.\d+\b"), "release number"), (re.compile(r"#\d+"), "issue number"),
             (re.compile(r"(?i)\b(phase|фаза|фазы)\s*\d"), "phase name"), (re.compile(r"\bM[1-3]\b"), "milestone name"),
             (re.compile(r"(?i)\b(release|релиз)\s*\d"), "release name"), (re.compile(r"\b[rmp][1-4]-[a-z0-9]+\b"), "agent name")]
for lang in ("en", "ru"):
    base = os.path.join(mod, "locale", lang)
    for fn in sorted(os.listdir(base)):
        if not fn.endswith(".cfg"): continue
        for n, line in enumerate(open(os.path.join(base, fn), encoding="utf-8"), 1):
            s = line.rstrip("\n")
            if not s.strip() or s.startswith("#") or s.startswith(";") or "=" not in s: continue
            v = s.split("=", 1)[1]
            for rx, what in FORBIDDEN:
                m = rx.search(v)
                if m: problems.append("%s/%s:%d: %s in player text: %r" % (lang, fn, n, what, m.group(0)))
print("help-check: %d entries, %d EN keys, %d RU keys, %d problems" % (len(entries), len(keys["en"]), len(keys["ru"]), len(problems)))
for p in problems: print("  " + p)
sys.exit(1 if problems else 0)
