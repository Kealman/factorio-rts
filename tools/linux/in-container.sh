#!/usr/bin/env bash
# Runs inside the tools/linux/Dockerfile image; tools/linux/run.sh starts it. Mounts: /rts the repository (read-only),
# /mod the mod under test (read-only), /out the results. Each scenario runs through tools/autotest-run.sh, the runner of
# the macOS tests, on the container's own file system, which is case-sensitive: the runner copies /mod there first.
# After the smoke of each variant, data.raw of that copy is dumped for tools/linux/case-check.py.
# Usage: in-container.sh <variant>:<scenario>...   variant base|sa, scenario smoke|nation|skirmish
# Env: SEED (default 9090), CAP_SCALE (multiplies the wall-clock caps; run.sh raises it for an emulated architecture).
set -uo pipefail
export RTS_BUILD_DIR=/tmp/rts-build KEEP_TREE=/mod
mkdir -p "$RTS_BUILD_DIR"
source /rts/tools/factorio-env.sh
"$FACTORIO_BIN" --version > /out/factorio-version.txt 2>&1
SCALE="${CAP_SCALE:-1}"

run() {
  local variant="$1" scen="$2" name="linux-$2-$1" match cap
  case "$scen" in
    smoke)    match='{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}'; cap=600 ;;
    nation)   match='{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}'; cap=1500 ;;
    skirmish) match='{opponents = 1, difficulty = "normal", size = "medium", enemy_brain = "ai"}'; cap=1200 ;;
    *) echo "unknown scenario $scen" > "/out/$name.txt"; return ;;
  esac
  VARIANT="$variant" SEED="${SEED:-9090}" /rts/tools/autotest-run.sh "$name" "$match" "$(( cap * SCALE ))" \
    > "/out/$name.txt" 2>&1
  cp "$RTS_BUILD_DIR/$name-server.log" "$RTS_BUILD_DIR/$name-create.log" /out/ 2>/dev/null
  if [ "$scen" = smoke ]; then # data.raw of this variant: every sprite and sound path the mod's prototypes end up with
    local cfg; cfg="$(factorio_isolated_config "$name-dump")"
    "$FACTORIO_BIN" -c "$cfg" --mod-directory "$RTS_BUILD_DIR/$name" --dump-data > "/out/$name-dump.out" 2>&1
    cp "$RTS_BUILD_DIR/runs/$name-dump/script-output/data-raw-dump.json" "/out/data-raw-dump-$variant.json" 2>/dev/null \
      || echo "no data-raw-dump.json" >> "/out/$name-dump.out"
  fi
}

for spec in "$@"; do
  run "${spec%%:*}" "${spec##*:}" &
done
wait
