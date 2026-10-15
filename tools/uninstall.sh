#!/usr/bin/env bash
# Remove the factorio-rts mod from the user's mods folder and restore the newest mod-list backup.
set -euo pipefail
USER_MODS="$HOME/Library/Application Support/factorio/mods"
rm -rf "$USER_MODS/factorio-rts" "$USER_MODS"/factorio-rts_*.zip
B=$(ls -t "$USER_MODS"/mod-list.backup-*.json 2>/dev/null | head -1 || true)
if [ -n "$B" ]; then cp "$B" "$USER_MODS/mod-list.json"; echo "restored $B"; else echo "no backup found; mod-list.json left as is"; fi
echo "removed factorio-rts"
