#!/usr/bin/env bash
# Shared environment for Factorio tooling. Source this file.
# FACTORIO_BIN and RTS_BUILD_DIR may be set by the caller: tools/linux/run.sh runs these tools inside Docker with the
# headless Linux build (FACTORIO_BIN=/opt/factorio/bin/<arch>/factorio) and a build dir on the container's own file system.
export FACTORIO_APP="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app"
export FACTORIO_BIN="${FACTORIO_BIN:-$FACTORIO_APP/Contents/MacOS/factorio}"
export FACTORIO_DOCS="$FACTORIO_APP/Contents/doc-html"
export FACTORIO_DATA="$FACTORIO_APP/Contents/data"
# works when sourced from bash (BASH_SOURCE) or zsh (%x prompt expansion)
_rts_self="${BASH_SOURCE[0]:-${(%):-%x}}"
export RTS_ROOT="$(cd "$(dirname "$_rts_self")/.." && pwd)"
export RTS_MODS_DIR="$RTS_ROOT/mods"          # our mod(s) live here, symlinked or copied
export RTS_BUILD_DIR="${RTS_BUILD_DIR:-$RTS_ROOT/build}" # generated saves and logs
mkdir -p "$RTS_BUILD_DIR"
# The Steam build exits with "Steam requires game restart" when launched directly unless these are set
# (found 2026-10-15 in the camera spike). Steam itself must be running for the GUI client.
export SteamAppId=427520
export SteamGameId=427520
export FACTORIO_SCRIPT_OUTPUT="$HOME/Library/Application Support/factorio/script-output"

# Factorio takes an exclusive lock on its write-data dir (.lock), so parallel runs need separate
# write dirs. factorio_isolated_config <run-id> prints the path of a per-run config.ini.
# FACTORIO_READ_DATA: the game's data directory for that config. The default suits the macOS app; on Linux
# __PATH__system-read-data__ means /usr/share/factorio, so the Docker image sets /opt/factorio/data.
factorio_isolated_config() {
  local id="$1" dir="$RTS_BUILD_DIR/runs/$1"
  mkdir -p "$dir"
  # [controls]: GRAVE only opens the console on a Latin keyboard layout; F9 works with any input source (QA runs).
  printf '[path]\nread-data=%s\nwrite-data=%s\n\n[other]\ncheck-updates=false\n\n[controls]\ntoggle-console-alternative=F9\n' \
    "${FACTORIO_READ_DATA:-__PATH__system-read-data__}" "$dir" > "$dir/config.ini"
  # RTS_LOCALE=ru (GUI runs): the client's language
  if [ -n "${RTS_LOCALE:-}" ]; then printf '\n[general]\nlocale=%s\n' "$RTS_LOCALE" >> "$dir/config.ini"; fi
  echo "$dir/config.ini"
}

# factorio_version_guard <mod dir>: refuse (exit 3, one line) when the binary's major.minor differs from the mod's
# info.json factorio_version, in either direction (a Steam update to 2.1 failed every 2.0 run at map creation).
factorio_version_guard() {
  local info="$1/info.json" bin want
  bin="$("$FACTORIO_BIN" --version 2>/dev/null | head -1 | sed -E 's/^Version: ([0-9]+\.[0-9]+).*/\1/')"
  want="$(sed -nE 's/.*"factorio_version": *"([0-9]+\.[0-9]+)".*/\1/p' "$info" 2>/dev/null | head -1)"
  if [ -z "$bin" ] || [ -z "$want" ] || [ "$bin" != "$want" ]; then
    echo "refused: Factorio ${bin:-not found} but $info wants ${want:-unknown}"
    exit 3
  fi
}
