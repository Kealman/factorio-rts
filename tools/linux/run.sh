#!/usr/bin/env bash
# Linux check in one command: downloads the official Factorio headless build for Linux (no account needed), checks it
# against factorio.com's SHA-256 list, builds a Docker image with it (tools/linux/Dockerfile) and runs the mod's headless
# autotests in a container through tools/autotest-run.sh, the runner of the macOS tests, on a case-sensitive file
# system. Then tools/linux/case-check.py checks every require and every file path of data.raw for case mismatches.
#
# Usage: tools/linux/run.sh            the Skirmish smoke (65 checks) and the Nation smoke, base game and Space Age
# Env:
#   FACTORIO_VERSION=2.1.23    the headless build
#   ARCH=amd64|arm64           container platform (default: the Docker host's; amd64 on Apple silicon runs emulated)
#   VARIANTS="base sa"         base game only and/or Space Age (the headless build carries the Space Age data)
#   SCENARIOS="smoke nation"   smoke: legacy units, 1v1 small, waves; nation: 1v1 Nation 2048, AI, 8 min;
#                              skirmish: 1v1 normal medium, AI
#   TREE=<dir>                 the mod to test (default mods/factorio-rts)
#   SEED=9090                  map seed
#   OUT=<dir>                  results (default build/linux/out-<version>-<arch>)
# Needs: Docker (daemon running), curl, python3. Exit status 0 when every run passed every check without a Lua error
# and the case check passed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${FACTORIO_VERSION:-2.1.23}"
VARIANTS="${VARIANTS:-base sa}"; SCENARIOS="${SCENARIOS:-smoke nation}"
TREE="$(cd "${TREE:-$ROOT/mods/factorio-rts}" && pwd)" || { echo "no mod tree"; exit 2; }
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running (docker info failed)"; exit 2; }
if [ -z "${ARCH:-}" ]; then
  case "$(docker info --format '{{.Architecture}}')" in aarch64|arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
fi
case "$ARCH" in
  amd64) DL=linux64; FILE="factorio-headless_linux_$VERSION.tar.xz"; BIN_DIR=x64 ;;
  arm64) DL=linux-arm64; FILE="factorio-headless_linux-arm64_$VERSION.tar.xz"; BIN_DIR=arm64 ;;
  *) echo "ARCH must be amd64 or arm64"; exit 2 ;;
esac
OUT_DEFAULT="$ROOT/build/linux/out-$VERSION-$ARCH"
OUT="${OUT:-$OUT_DEFAULT}"
IMAGE="factorio-rts-headless:$VERSION-$ARCH"

# 1. the headless archive, alone in its own directory (it is the image's build context)
DLDIR="$ROOT/build/linux/dl-$VERSION-$DL"
mkdir -p "$DLDIR"
if [ ! -f "$DLDIR/$FILE" ]; then
  echo "downloading $FILE"
  curl -fSL --retry 3 -o "$DLDIR/$FILE.part" "https://factorio.com/get-download/$VERSION/headless/$DL" \
    && mv "$DLDIR/$FILE.part" "$DLDIR/$FILE" || { rm -f "$DLDIR/$FILE.part"; echo "download failed"; exit 1; }
fi
WANT="$(curl -fsSL https://factorio.com/download/sha256sums/ | awk -v f="$FILE" '$2 == f {print $1}')"
if command -v sha256sum >/dev/null 2>&1; then GOT="$(sha256sum "$DLDIR/$FILE" | cut -d' ' -f1)"
else GOT="$(shasum -a 256 "$DLDIR/$FILE" | cut -d' ' -f1)"; fi
[ -n "$WANT" ] || { echo "$FILE is not in factorio.com's SHA-256 list"; exit 1; }
[ "$WANT" = "$GOT" ] || { echo "SHA-256 mismatch for $FILE: got $GOT, want $WANT"; exit 1; }
echo "$FILE: SHA-256 ok"

# 2. the image
[ "$OUT" = "$OUT_DEFAULT" ] && rm -rf "$OUT" # a directory given as OUT is only written into
mkdir -p "$OUT"
docker build --platform "linux/$ARCH" -t "$IMAGE" -f "$ROOT/tools/linux/Dockerfile" \
  --build-arg FACTORIO_ARCHIVE="$FILE" --build-arg FACTORIO_BIN_DIR="$BIN_DIR" "$DLDIR" > "$OUT/docker-build.log" 2>&1 \
  || { tail -20 "$OUT/docker-build.log"; echo "docker build failed (log: $OUT/docker-build.log)"; exit 1; }

# 3. the runs (in parallel inside one container); an emulated architecture gets 4x the wall-clock caps
SCALE=1
case "$(docker info --format '{{.Architecture}}')" in aarch64|arm64) [ "$ARCH" = amd64 ] && SCALE=4 ;; *) [ "$ARCH" = arm64 ] && SCALE=4 ;; esac
SPECS=()
for v in $VARIANTS; do for s in $SCENARIOS; do SPECS+=("$v:$s"); done; done
echo "running ${SPECS[*]} on $IMAGE (results in $OUT)"
START=$(date +%s)
docker run --rm --platform "linux/$ARCH" --user "$(id -u):$(id -g)" \
  -e SEED="${SEED:-9090}" -e CAP_SCALE="$SCALE" \
  -v "$ROOT:/rts:ro" -v "$TREE:/mod:ro" -v "$OUT:/out" \
  "$IMAGE" bash /rts/tools/linux/in-container.sh "${SPECS[@]}"
echo "container done in $(( $(date +%s) - START )) s: $(head -1 "$OUT/factorio-version.txt")"

# 4. results
FAIL=0
for spec in "${SPECS[@]}"; do
  name="linux-${spec##*:}-${spec%%:*}"; f="$OUT/$name.txt"
  summary="$(grep -hE "autotest summary" "$f" 2>/dev/null | tail -1 | sed -E 's/.*(autotest summary)/\1/')"
  errs="$(sed -n '/=== errors ===/,/^log:/p' "$f" 2>/dev/null | grep -vcE '^(=== errors ===|log:|\(none\))')"
  status="$(head -1 "$f" 2>/dev/null)"
  ok=PASS
  [[ "$summary" == *"(all passed)"* ]] || ok=FAIL
  [ "${errs:-1}" = 0 ] || ok=FAIL
  [ "$ok" = PASS ] || FAIL=1
  echo "$ok $name | ${summary:-no summary} | errors ${errs:-?} | $status"
done
DUMPS=()
for d in "$OUT"/data-raw-dump-*.json; do [ -f "$d" ] && DUMPS+=(--dump "$d"); done
DATA=()
if [ "$(uname)" = Darwin ]; then
  source "$ROOT/tools/factorio-env.sh"
  [ -d "$FACTORIO_DATA/base/graphics" ] && DATA=(--data "$FACTORIO_DATA")
elif [ -d "${FACTORIO_DATA:-}/base/graphics" ]; then
  DATA=(--data "$FACTORIO_DATA") # a full Linux client's data directory, e.g. ~/.steam/steam/steamapps/common/Factorio/data
fi
# ${A[@]+"${A[@]}"}: an empty array under set -u in bash 3.2 (macOS)
python3 -I "$ROOT/tools/linux/case-check.py" "$TREE" ${DATA[@]+"${DATA[@]}"} ${DUMPS[@]+"${DUMPS[@]}"} \
  > "$OUT/case-check.txt" || FAIL=1
grep -E "^(case check|FAIL)" "$OUT/case-check.txt"
echo "logs: $OUT"
exit $FAIL
