#!/usr/bin/env bash
# Install (or update) the factorio-rts mod into the user's real Factorio mods folder and enable only
# the mods it needs. The previous mod-list.json is backed up once as mod-list.backup-<date>.json.
# Usage: tools/install.sh        (re-run after every update; safe to repeat)
#        tools/uninstall.sh      (removes the mod and restores the newest backup)
set -euo pipefail
source "$(dirname "$0")/factorio-env.sh"
USER_MODS="$HOME/Library/Application Support/factorio/mods"
SRC="$RTS_ROOT/mods/factorio-rts"
mkdir -p "$USER_MODS"
[ -f "$USER_MODS/mod-list.json" ] && [ -z "$(ls "$USER_MODS"/mod-list.backup-*.json 2>/dev/null)" ] \
  && cp "$USER_MODS/mod-list.json" "$USER_MODS/mod-list.backup-$(date +%Y%m%d-%H%M%S).json"
rm -rf "$USER_MODS/factorio-rts" "$USER_MODS"/factorio-rts_*.zip
cp -R "$SRC" "$USER_MODS/factorio-rts"
python3 - "$USER_MODS/mod-list.json" <<'PY'
import json, sys
path = sys.argv[1]
keep = {"base", "space-age", "quality", "elevated-rails", "factorio-rts"}
try:
    data = json.load(open(path))
except Exception:
    data = {"mods": []}
names = {m["name"] for m in data["mods"]}
for name in keep - names:
    data["mods"].append({"name": name, "enabled": True})
for m in data["mods"]:
    m["enabled"] = m["name"] in keep      # old 1.1-era mods stay listed but disabled
json.dump(data, open(path, "w"), indent=2, ensure_ascii=False)
print("enabled:", sorted(n for n in keep))
PY
echo "installed $SRC -> $USER_MODS/factorio-rts"
echo "Start Factorio, create a New game (Freeplay), and the RTS lobby opens on join."
