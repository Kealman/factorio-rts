#!/usr/bin/env bash
# Shared environment for Factorio tooling. Source this file.
export FACTORIO_APP="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app"
export FACTORIO_BIN="$FACTORIO_APP/Contents/MacOS/factorio"
export FACTORIO_DOCS="$FACTORIO_APP/Contents/doc-html"
export FACTORIO_DATA="$FACTORIO_APP/Contents/data"
# works when sourced from bash (BASH_SOURCE) or zsh (%x prompt expansion)
_rts_self="${BASH_SOURCE[0]:-${(%):-%x}}"
export RTS_ROOT="$(cd "$(dirname "$_rts_self")/.." && pwd)"
export RTS_MODS_DIR="$RTS_ROOT/mods"          # our mod(s) live here, symlinked or copied
export RTS_BUILD_DIR="$RTS_ROOT/build"        # generated saves and logs
mkdir -p "$RTS_BUILD_DIR"
# The Steam build exits with "Steam requires game restart" when launched directly unless these are set
# (found 2026-10-15 in the camera spike). Steam itself must be running for the GUI client.
export SteamAppId=427520
export SteamGameId=427520
export FACTORIO_SCRIPT_OUTPUT="$HOME/Library/Application Support/factorio/script-output"

# Factorio takes an exclusive lock on its write-data dir (.lock), so parallel runs need separate
# write dirs. factorio_isolated_config <run-id> prints the path of a per-run config.ini.
factorio_isolated_config() {
  local id="$1" dir="$RTS_BUILD_DIR/runs/$1"
  mkdir -p "$dir"
  printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n\n[other]\ncheck-updates=false\n' "$dir" > "$dir/config.ini"
  echo "$dir/config.ini"
}
