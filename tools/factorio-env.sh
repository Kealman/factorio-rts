#!/usr/bin/env bash
# Shared environment for Factorio tooling. Source this file.
export FACTORIO_APP="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app"
export FACTORIO_BIN="$FACTORIO_APP/Contents/MacOS/factorio"
export FACTORIO_DOCS="$FACTORIO_APP/Contents/doc-html"
export FACTORIO_DATA="$FACTORIO_APP/Contents/data"
export RTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RTS_MODS_DIR="$RTS_ROOT/mods"          # our mod(s) live here, symlinked or copied
export RTS_BUILD_DIR="$RTS_ROOT/build"        # generated saves and logs
mkdir -p "$RTS_BUILD_DIR"
