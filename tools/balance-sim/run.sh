#!/usr/bin/env bash
# Balance simulator run (docs/qa/phase4-balance-notes.md): copies mods/factorio-rts to build/<name>/, adds
# tools/balance-sim/balancesim.lua as scripts/balancesim.lua (required at the end of the copy's control.lua) and runs
# a headless server until "[rts] bsim done" (or CAP seconds). Usage: tools/balance-sim/run.sh <name> [sa|base] [cap=400]
# Env: SIM_FROM_HEAD="scripts/hud.lua" takes those files from git HEAD instead of the working tree.
set -uo pipefail
source "$(dirname "$0")/../factorio-env.sh"
NAME="${1:?name}"; VARIANT="${2:-sa}"; CAP="${3:-400}"
DIR="$RTS_BUILD_DIR/$NAME"
rm -rf "$DIR"; mkdir -p "$DIR"
cp -R "$RTS_MODS_DIR/factorio-rts" "$DIR/"
cp "$RTS_ROOT/tools/balance-sim/balancesim.lua" "$DIR/factorio-rts/scripts/balancesim.lua"
# SIM_FROM_HEAD="scripts/hud.lua ...": take these mod files from git HEAD (another agent's half-finished edit in the
# working tree must not stop a balance run; the simulator does not use the HUD).
for f in ${SIM_FROM_HEAD:-}; do
  git -C "$RTS_ROOT" show "HEAD:mods/factorio-rts/$f" > "$DIR/factorio-rts/$f" && echo "from HEAD: $f"
done
printf '\nrequire("scripts.balancesim") -- balance simulator (test copy only)\n' >> "$DIR/factorio-rts/control.lua"
# SIM_TRACE=1: per-scenario trace lines every 0.5 s (round 1) with shot counts from script triggers on every unit attack
if [ -n "${SIM_TRACE:-}" ]; then
  cp "$RTS_ROOT/tools/balance-sim/diag-data-final-fixes.lua" "$DIR/factorio-rts/data-final-fixes.lua"
  sed -i '' "s|^sim.TRACE = false|sim.TRACE = true|" "$DIR/factorio-rts/scripts/balancesim.lua"
fi
if [ -n "${SIM_ONLY:-}" ]; then
  sed -i '' "s|^sim.ONLY = nil|sim.ONLY = \"$SIM_ONLY\"|" "$DIR/factorio-rts/scripts/balancesim.lua"
fi
if [ "$VARIANT" = "base" ]; then
  printf '{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":false},{"name":"quality","enabled":false},{"name":"space-age","enabled":false},{"name":"factorio-rts","enabled":true}]}\n' > "$DIR/mod-list.json"
else
  cp "$RTS_MODS_DIR/mod-list.json" "$DIR/"
fi
CFG="$(factorio_isolated_config "$NAME")"
PORT=$(( 34200 + ( $(cksum <<< "$NAME" | cut -d" " -f1) % 300 ) ))
SAVE="$RTS_BUILD_DIR/$NAME-headless.zip"; LOG="$RTS_BUILD_DIR/$NAME-server.log"
rm -f "$SAVE"
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --create "$SAVE" > "$RTS_BUILD_DIR/$NAME-create.log" 2>&1 \
  || { echo "map creation failed"; grep -iE "error" "$RTS_BUILD_DIR/$NAME-create.log" | head; exit 1; }
"$FACTORIO_BIN" -c "$CFG" --mod-directory "$DIR" --start-server "$SAVE" --port "$PORT" \
  --server-settings "$RTS_ROOT/tools/server-settings.json" > "$LOG" 2>&1 &
PID=$!
for i in $(seq 1 "$CAP"); do
  sleep 1
  kill -0 "$PID" 2>/dev/null || { echo "server exited after $i s"; break; }
  grep -q "\[rts\] bsim done" "$LOG" && { echo "done after $i s"; break; }
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
grep -E "\[rts\] bsim" "$RTS_BUILD_DIR/$NAME-create.log" "$LOG" | sed -E 's/^.*\[rts\] bsim /bsim /'
grep -E "Error|rror while running" "$LOG" | head -5
