#!/usr/bin/env python3
"""Case check for Linux (tools/linux/run.sh). Linux file systems are case-sensitive, macOS and Windows usually are not,
so a path whose case differs from the file on disk works on the development Mac and fails on Linux.

Checks, comparing every path component with the real directory listing (exact case, independent of the file system):
  1. every literal require("...") in the mod's Lua files resolves to a file of the mod, or of core/lualib in the game data;
  2. every literal "__factorio-rts__/..." file path exists in the mod;
  3. with --dump: every "__mod__/....ext" file path in data.raw (factorio --dump-data, after every data stage, so computed
     paths count too) exists in the game data (--data, the full client's data directory: the headless build ships no
     graphics or sounds) or in the mod.
A path that exists only with another case is a FAIL. A path missing in every case is listed apart: vanilla prototypes
reference a few files that ship only on some platforms (console haptics).

Usage: case-check.py <mod dir> [--data <factorio data dir>] [--dump data-raw-dump.json]...
Exit status 1 when any check fails.
"""
import json
import os
import re
import sys

MOD_NAME = "factorio-rts"


class Tree:
    """Exact-case lookups with cached directory listings."""

    def __init__(self):
        self.cache = {}

    def listing(self, d):
        if d not in self.cache:
            try:
                self.cache[d] = set(os.listdir(d))
            except OSError:
                self.cache[d] = None
        return self.cache[d]

    def lookup(self, root, rel):
        """'ok', 'case' (exists with another case: the first differing component is returned too) or 'missing'."""
        cur = root
        for part in [p for p in rel.split("/") if p not in ("", ".")]:
            names = self.listing(cur)
            if names is None:
                return "missing", None
            if part in names:
                cur = os.path.join(cur, part)
                continue
            other = [n for n in names if n.lower() == part.lower()]
            return ("case", f"{part} -> on disk {other[0]}") if other else ("missing", None)
        return "ok", None


def lua_files(root):
    for d, _, files in os.walk(root):
        for f in files:
            if f.endswith(".lua"):
                yield os.path.join(d, f)


def main(argv):
    args = argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 2
    mod = os.path.abspath(args.pop(0))
    data, dumps = None, []
    while args:
        flag = args.pop(0)
        if flag == "--data":
            data = args.pop(0)
        elif flag == "--dump":
            dumps.append(args.pop(0))
        else:
            print(f"unknown argument {flag}")
            return 2
    tree = Tree()
    fails, missing, counts = [], [], {"require": 0, "own path": 0, "data.raw path": 0}

    req_re = re.compile(r"""require\s*\(?\s*["']([^"']+)["']""")
    own_re = re.compile(r"""["']__%s__/([^"']+\.[A-Za-z0-9]+)["']""" % re.escape(MOD_NAME))
    for path in lua_files(mod):
        rel_file = os.path.relpath(path, mod)
        text = open(path, encoding="utf-8", errors="replace").read()
        for n, line in enumerate(text.splitlines(), 1):
            code = line.split("--", 1)[0] if not line.lstrip().startswith("--") else ""
            for m in req_re.finditer(code):
                name = m.group(1)
                counts["require"] += 1
                own = f"__{MOD_NAME}__/"
                if name.startswith("__") and not name.startswith(own):
                    continue  # another mod's file; the Docker run loads it
                name = name[len(own):] if name.startswith(own) else name
                rel = name if name.endswith(".lua") else name.replace(".", "/") + ".lua"
                here = os.path.relpath(os.path.join(os.path.dirname(path), rel), mod)
                results = [tree.lookup(mod, rel), tree.lookup(mod, here)]
                if data:
                    results.append(tree.lookup(os.path.join(data, "core", "lualib"), rel))
                if any(r[0] == "ok" for r in results):
                    continue
                case = [r[1] for r in results if r[0] == "case"]
                if case:
                    fails.append(f"require {name!r} at {rel_file}:{n}: {case[0]}")
                elif data or "." in name or "/" in name:
                    missing.append(f"require {name!r} at {rel_file}:{n}: no such file in the mod" +
                                   ("" if data else " (no --data: core/lualib not checked)"))
            for m in own_re.finditer(code):
                counts["own path"] += 1
                status, detail = tree.lookup(mod, m.group(1))
                if status == "case":
                    fails.append(f"path __{MOD_NAME}__/{m.group(1)} at {rel_file}:{n}: {detail}")
                elif status == "missing":
                    missing.append(f"path __{MOD_NAME}__/{m.group(1)} at {rel_file}:{n}: not in the mod")

    path_re = re.compile(r"^__([A-Za-z0-9_-]+)__/(.+\.[A-Za-z0-9]{2,5})$")
    for dump in dumps:
        raw = json.load(open(dump, encoding="utf-8"))
        seen = {}

        def walk(node, where):
            if isinstance(node, dict):
                for k, v in node.items():
                    walk(v, where)
            elif isinstance(node, list):
                for v in node:
                    walk(v, where)
            elif isinstance(node, str):
                m = path_re.match(node)
                if m:
                    seen.setdefault(node, where)

        for ptype, protos in raw.items():
            if isinstance(protos, dict):
                for pname, proto in protos.items():
                    walk(proto, f"{ptype}/{pname}")
        for p, where in sorted(seen.items()):
            m = path_re.match(p)
            owner, rel = m.group(1), m.group(2)
            counts["data.raw path"] += 1
            if owner == MOD_NAME:
                status, detail = tree.lookup(mod, rel)
            elif data:
                status, detail = tree.lookup(os.path.join(data, owner), rel)
            else:
                continue
            ours = "rts-" in where or owner == MOD_NAME
            tag = f"{os.path.basename(dump)}: {p} (first used by {where})"
            if status == "case":
                fails.append(f"{tag}: {detail}")
            elif status == "missing":
                missing.append(f"{tag}: missing in every case{' [RTS prototype]' if ours else ''}")

    print("case check: " + ", ".join(f"{v} {k}s" for k, v in counts.items()) +
          ("" if data or not dumps else " (no --data: data.raw paths of other mods not checked)"))
    for f in fails:
        print("FAIL " + f)
    for f in missing:
        print("missing " + f)
    print(f"case check: {'PASS' if not fails else 'FAIL'} ({len(fails)} case mismatches, {len(missing)} missing in every case)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
