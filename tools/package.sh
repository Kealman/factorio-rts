#!/usr/bin/env bash
# Build the release archive of the mod: build/release/<name>_<version>.zip with the mod inside a <name>_<version>/
# folder, the layout the Factorio Mod Portal and the in-game mod manager expect. Name and version come from
# mods/factorio-rts/info.json; the version is never changed here (bump it in info.json and changelog.txt first).
#
# Usage: tools/package.sh            (from anywhere inside the repository)
#   SRC=<dir> tools/package.sh       package another tree (default: mods/factorio-rts of this checkout)
#
# The archive holds every file of the mod folder except editor and OS litter (.DS_Store, ._*, *.orig, *.rej, *.bak,
# *~, *.swp, Thumbs.db, dot-folders). It refuses a tree whose test-only autotest switch is on, and warns when the
# thumbnail, the changelog or the git state needs a look. Exit 0 = archive written; 1 = refused.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$ROOT/mods/factorio-rts}"
OUT_DIR="$ROOT/build/release"
INFO="$SRC/info.json"
fail() { echo "package: refused: $*" >&2; exit 1; }
warn() { echo "package: warning: $*" >&2; }

[ -f "$INFO" ] || fail "no info.json in $SRC"
read -r NAME VERSION FV < <(python3 -I - "$INFO" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("name", ""), d.get("version", ""), d.get("factorio_version", ""))
PY
)
[[ "$NAME" =~ ^[A-Za-z0-9_-]{4,49}$ ]] || fail "info.json name '$NAME' (the portal takes 4-49 characters of A-Z, a-z, 0-9, - and _)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "info.json version '$VERSION' is not number.number.number"
[[ "$FV" =~ ^[0-9]+\.[0-9]+$ ]] || fail "info.json factorio_version '$FV' is not number.number"
# Test copies switch the headless autotest on (tools/autotest-run.sh); a release must not ship that switch.
if grep -qE '^local AUTOTEST_ENABLED = true' "$SRC/scripts/debug.lua" 2>/dev/null; then
  fail "scripts/debug.lua has AUTOTEST_ENABLED = true (a test copy?)"
fi

# thumbnail.png: the portal and the mod browser show it; ideally 144x144 (Factorio docs, "Mod structure")
if [ -f "$SRC/thumbnail.png" ]; then
  size="$(python3 -I - "$SRC/thumbnail.png" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read(24)
print("%dx%d" % struct.unpack(">II", b[16:24]) if b[:8] == b"\x89PNG\r\n\x1a\n" else "not-a-png")
PY
)"
  [ "$size" = "144x144" ] || warn "thumbnail.png is $size (the portal expects 144x144)"
else
  warn "no thumbnail.png in the mod folder (the portal and the mod browser show a blank square)"
fi

# changelog.txt: the in-game mod browser's Changelog tab parses this strict format (doc-html/auxiliary/changelog-format)
if [ -f "$SRC/changelog.txt" ]; then
  python3 -I - "$SRC/changelog.txt" "$VERSION" <<'PY' || warn "changelog.txt does not parse (see the lines above)"
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
ok, versions = True, []
if not lines or lines[0] != "-" * 99:
    print("package: changelog.txt:1: the file must start with a line of exactly 99 dashes", file=sys.stderr); ok = False
for i, l in enumerate(lines, 1):
    if "\t" in l or l != l.rstrip(" "):
        print("package: changelog.txt:%d: tab or trailing space" % i, file=sys.stderr); ok = False
    if l.startswith("-") and l != "-" * 99:
        print("package: changelog.txt:%d: a section line must be exactly 99 dashes" % i, file=sys.stderr); ok = False
    if l == "-" * 99 and not (i < len(lines) and lines[i].startswith("Version: ")):
        print("package: changelog.txt:%d: the line after the dashes must be 'Version: x.y.z'" % i, file=sys.stderr); ok = False
    m = re.match(r"Version: (\S+)$", l)
    if m: versions.append(m.group(1))
if sys.argv[2] not in versions:
    print("package: changelog.txt has no 'Version: %s' section" % sys.argv[2], file=sys.stderr); ok = False
sys.exit(0 if ok else 1)
PY
else
  warn "no changelog.txt in the mod folder (the mod browser's Changelog tab stays empty)"
fi

if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && [ "$SRC" = "$ROOT/mods/factorio-rts" ]; then
  dirty="$(git -C "$ROOT" status --porcelain -- mods/factorio-rts)"
  [ -z "$dirty" ] || warn "mods/factorio-rts has uncommitted or untracked changes; the archive takes the working tree:
$dirty"
fi

FOLDER="${NAME}_${VERSION}"
ZIP="$OUT_DIR/$FOLDER.zip"
STAGE="$OUT_DIR/stage"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE/$FOLDER"
# copy the mod without OS and editor litter; dot-files and dot-folders never belong to a mod
( cd "$SRC" && find . -type f \
    ! -name '.*' ! -path '*/.*/*' ! -name '*.orig' ! -name '*.rej' ! -name '*.bak' ! -name '*~' ! -name '*.swp' \
    ! -name 'Thumbs.db' -print ) | sed 's|^\./||' | LC_ALL=C sort > "$STAGE/files.txt"
while IFS= read -r f; do
  mkdir -p "$STAGE/$FOLDER/$(dirname "$f")"
  cp -p "$SRC/$f" "$STAGE/$FOLDER/$f"
done < "$STAGE/files.txt"
# -X: no extra file attributes (macOS), entries in sorted order for a stable archive
( cd "$STAGE" && sed "s|^|$FOLDER/|" files.txt | zip -X -q "$ZIP" -@ )
rm -rf "$STAGE"

# check the result: every entry under <name>_<version>/, info.json at its root
entries="$(unzip -Z1 "$ZIP")"
outside="$(printf '%s\n' "$entries" | grep -v "^$FOLDER/" || true)"
[ -z "$outside" ] || fail "entries outside $FOLDER/ in $ZIP: $outside"
printf '%s\n' "$entries" | grep -qx "$FOLDER/info.json" || fail "$ZIP has no $FOLDER/info.json"
bytes="$(wc -c < "$ZIP" | tr -d ' ')"
count="$(printf '%s\n' "$entries" | grep -vc '/$')"
echo "package: $ZIP"
echo "package: $count files, $bytes bytes ($(awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b / 1048576 }')), Factorio $FV"
