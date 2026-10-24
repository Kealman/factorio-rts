#!/usr/bin/env bash
# Showcase: regenerates the staged release screenshots and the mod portal thumbnail (mods/factorio-rts/thumbnail.png,
# 144x144). Every shot is a scripted scene of tools/probes/showcase_*.lua played in a real GUI client (no human
# input): the probe spawns, gives and positions everything with the QA shortcuts' module calls, moves the camera and
# logs "RTS_DRIVE <n> capture <name>"; tools/gui-drive.sh grabs the client window and this script crops its 28 px title
# bar. docs/media/INDEX.md lists which launch and scene makes each file.
#
# Output of every shot (by default):
#   build/showcase/full/<name>.png   the full-size 1920x1080 original (lossless; for the Mod Portal gallery upload)
#   docs/media/<name>.png            the web version for the repository: WEB_WIDTH px wide (1600), pngquant at
#                                    WEB_QUALITY (70-90), then oxipng (when installed: brew install pngquant oxipng)
#   build/showcase/alt/alt-*.png     alternate takes (other moments and framings), full size, never in the repository
# WEB_FORMAT=webp writes docs/media/<name>.webp (cwebp -q WEB_WEBP_Q, default 85) instead of the PNG.
#
# Usage: tools/showcase.sh <command> [scene...]
#   all            lobby, bake, nation, skirmish, thumb (about 15 minutes of wall clock; one GUI client at a time)
#   lobby          launch 1: the Nation lobby (01-lobby) and a 6-nation 4096 world (12-world-4096)
#   bake           launch 2a: a 3-nation 2048 Nation match where the AI also plays your nation for BAKE_MIN game minutes
#                  (default 60) at game speed 64; saved to build/showcase/nation-bake.zip
#   nation [s...]  launch 2b: loads the bake and stages the Nation scenes (02-11, 15), or only the named ones
#   skirmish [s..] launch 3: a Skirmish match (13-commander-abilities, 14-skirmish-base)
#   thumb          a full-size shot (THUMB_SHOT, default 13): its square THUMB_CROP (w:h:x:y) -> the 144x144
#                  mods/factorio-rts/thumbnail.png; the square itself -> docs/media/thumbnail-source.png (web version)
#   web [name...]  the web versions again from build/showcase/full/ (all, or the named shots)
#   full           list the full-size originals (build/showcase/full/)
#   crop <launch>  crop the raw window grabs of a launch again (build/showcase/raw/<launch>/)
# Env: SHOW_SEED (nation world seed, default 4242), SKIRMISH_SEED (default 777), BAKE_MIN, SHOTS=1 (also engine
#      screenshots, build/shots-showcase-*/), WEB_WIDTH, WEB_QUALITY, WEB_FORMAT, WEB_WEBP_Q. Raw window grabs stay in
#      build/showcase/raw/. Steam must be running; the game is English (RTS_LOCALE=en).
# The tree is `git archive HEAD mods/factorio-rts` plus the probes, so the shots show the committed mod.
set -u
source "$(dirname "$0")/factorio-env.sh"
cd "$RTS_ROOT"
export RTS_LOCALE=en
W=1920; H=1080
MEDIA="$RTS_ROOT/docs/media"
SHOW="$RTS_BUILD_DIR/showcase"
RAW="$SHOW/raw"
FULL="$SHOW/full"
BAKE="$SHOW/nation-bake.zip"
SHOW_SEED="${SHOW_SEED:-4242}"; SKIRMISH_SEED="${SKIRMISH_SEED:-777}"; BAKE_MIN="${BAKE_MIN:-60}"
WEB_WIDTH="${WEB_WIDTH:-1600}"; WEB_QUALITY="${WEB_QUALITY:-70-90}"; WEB_FORMAT="${WEB_FORMAT:-png}"
WEB_WEBP_Q="${WEB_WEBP_Q:-85}"
mkdir -p "$MEDIA" "$RAW" "$FULL" "$SHOW/alt"

no_client() {
  if pgrep -f '^/Users/.*/MacOS/factorio .*--window-size' >/dev/null; then
    echo "showcase: another GUI client is running (pid $(pgrep -f '^/Users/.*/MacOS/factorio .*--window-size' | head -1)); wait for it"
    exit 4
  fi
}

lua_list() { # scene names -> a Lua list or nil
  [ $# -eq 0 ] && { echo nil; return; }
  local s="{" n
  for n in "$@"; do s="$s\"$n\", "; done
  echo "$s}"
}

# tree <launch> <probe> <cfg lua>: build/showcase-<launch>/{factorio-rts, mod-list.json}
tree() {
  local dir="$RTS_BUILD_DIR/showcase-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  git archive HEAD mods/factorio-rts | tar -x -C "$dir" --strip-components=1
  cp mods/mod-list.json "$dir/"
  cp tools/probes/showcase_*.lua "$dir/factorio-rts/scripts/"
  printf '%s\n' "$3" > "$dir/factorio-rts/scripts/showcase_cfg.lua"
  printf '\n-- test copy (tools/showcase.sh)\nrequire("scripts.showcase_%s")\n' "$2" >> "$dir/factorio-rts/control.lua"
}

# web <full-size png> [out name]: the repository version in docs/media/ (see the header)
web() {
  local src="$1" name="${2:-$(basename "$1" .png)}" tmp="$SHOW/web-tmp.png" out
  ffmpeg -v error -y -i "$src" -vf "scale='min($WEB_WIDTH,iw)':-2:flags=lanczos" "$tmp" || return 1
  if [ "$WEB_FORMAT" = webp ]; then
    out="$MEDIA/$name.webp"
    cwebp -quiet -q "$WEB_WEBP_Q" "$tmp" -o "$out" && rm -f "$MEDIA/$name.png"
  else
    out="$MEDIA/$name.png"
    if command -v pngquant >/dev/null; then
      pngquant --quality "$WEB_QUALITY" --speed 1 --strip --force --output "$out" -- "$tmp" \
        || { echo "showcase: pngquant could not reach $WEB_QUALITY for $name: kept the scaled PNG"; cp "$tmp" "$out"; }
    else
      echo "showcase: pngquant not installed (brew install pngquant oxipng): $name is the scaled PNG only"
      cp "$tmp" "$out"
    fi
    command -v oxipng >/dev/null && oxipng -o 4 --strip safe -q "$out"
  fi
  rm -f "$tmp"
  printf 'showcase: web %-26s %5d KB\n' "$name" $(( $(stat -f %z "$out") / 1024 ))
}

# crop <launch>: raw window grabs (title bar on top) -> build/showcase/full/<name>.png (1920x1080) and the web version
# in docs/media/; alternates (alt-*.png) -> build/showcase/alt/ only
crop() {
  local f h top n=0 name
  for f in "$RAW/$1"/*.png; do
    [ -f "$f" ] || continue
    h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
    top=$(( h - H ))
    if [ "$top" -lt 0 ]; then echo "showcase: $f is ${h} px tall, skipped"; continue; fi
    name="$(basename "$f")"
    case "$name" in
      alt-*) ffmpeg -v error -y -i "$f" -vf "crop=$W:$H:0:$top" "$SHOW/alt/$name" && n=$(( n + 1 )) ;;
      *) ffmpeg -v error -y -i "$f" -vf "crop=$W:$H:0:$top" "$FULL/$name" && web "$FULL/$name" && n=$(( n + 1 )) ;;
    esac
  done
  echo "showcase: $n shot(s) of $1 (full size in build/showcase/full/, web versions in docs/media/, alternates in build/showcase/alt/)"
}

# run <launch> <cap seconds> <marker> [save to load]: one GUI client with gui-drive grabbing its window
run() {
  local launch="$1" cap="$2" marker="$3" load="${4:-}"
  local dir="$RTS_BUILD_DIR/showcase-$launch" log="$RTS_BUILD_DIR/showcase-$launch-gui.log"
  local raw="$RAW/$launch"
  no_client
  rm -rf "$raw"; mkdir -p "$raw"; rm -f "$log"
  tools/gui-drive.sh "$log" "$raw" "$marker" > "$SHOW/$launch-drive.out" 2>&1 &
  local drive=$!
  if [ -z "$load" ]; then
    RTS_WINDOW="${W}x${H}" tools/gui-run.sh "$dir" "$cap" "$marker" '\[rts\] showcase|rror' > "$SHOW/$launch-run.out" 2>&1
  else
    # a saved game: gui-run.sh always creates a new map, so the client is started here the same way
    factorio_version_guard "$dir/factorio-rts"
    local cfgini; cfgini="$(factorio_isolated_config "showcase-$launch-gui")"
    "$FACTORIO_BIN" -c "$cfgini" --mod-directory "$dir" --load-game "$load" --window-size "${W}x${H}" --disable-audio \
      > "$log" 2>&1 &
    local pid=$! i
    echo "started pid $pid at $(date +%T) from $load" > "$SHOW/$launch-run.out"
    for i in $(seq 1 "$cap"); do
      sleep 1
      kill -0 "$pid" 2>/dev/null || { echo "client exited on its own after $i s" >> "$SHOW/$launch-run.out"; break; }
      grep -q "$marker" "$log" && { echo "marker seen after $i s" >> "$SHOW/$launch-run.out"; sleep 3; break; }
    done
    kill "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  fi
  sleep 2; kill "$drive" 2>/dev/null; wait "$drive" 2>/dev/null
  grep -E '\[rts\] showcase|rror' "$log" | grep -v 'RTS_DRIVE' | tail -40
  grep -c 'captured' "$SHOW/$launch-drive.out" | sed 's/^/showcase: window grabs: /'
  if [ -n "${SHOTS:-}" ]; then
    local so="$RTS_BUILD_DIR/runs/showcase-$launch-gui/script-output"
    ls "$so"/showcase-*.png >/dev/null 2>&1 && { mkdir -p "$RTS_BUILD_DIR/shots-showcase-$launch"; mv "$so"/showcase-*.png "$RTS_BUILD_DIR/shots-showcase-$launch/"; }
  fi
}

cfg() { # <launch> <phase> <only list> [extra fields]
  printf 'return {launch = "%s", phase = "%s", width = %d, height = %d, only = %s, screenshots = %s, freeze_speed = 0.1%s}' \
    "$1" "$2" "$W" "$H" "$3" "$( [ -n "${SHOTS:-}" ] && echo true || echo false )" "${4:-}"
}

cmd_lobby() {
  tree lobby lobby "$(cfg lobby shoot "$(lua_list "$@")" ", seed = $SHOW_SEED")"
  run lobby 1500 "SHOWCASE_DONE lobby"
  crop lobby
}

cmd_bake() {
  tree nation-bake nation "$(cfg nation bake nil ", seed = $SHOW_SEED, nations = 3, world_size = 2048, difficulty = \"normal\", ai_difficulty = \"hard\", doctrine = \"economic\", bake_speed = 64, bake_minutes = $BAKE_MIN")"
  run nation-bake 3000 "SHOWCASE_BAKED nation"
  local save="$RTS_BUILD_DIR/runs/showcase-nation-bake-gui/saves/_autosave-showcase-nation.zip"
  if [ -f "$save" ]; then cp "$save" "$BAKE"; echo "showcase: bake saved to $BAKE"; else echo "showcase: no bake save ($save)"; exit 1; fi
}

cmd_nation() {
  [ -f "$BAKE" ] || { echo "showcase: no $BAKE: run tools/showcase.sh bake first"; exit 1; }
  tree nation-shoot nation "$(cfg nation shoot "$(lua_list "$@")" ", seed = $SHOW_SEED")"
  run nation-shoot 2400 "SHOWCASE_DONE nation" "$BAKE"
  crop nation-shoot
}

cmd_skirmish() {
  tree skirmish skirmish "$(cfg skirmish shoot "$(lua_list "$@")" ", seed = $SKIRMISH_SEED, bake_minutes = 14, bake_speed = 32")"
  run skirmish 1500 "SHOWCASE_DONE skirmish"
  crop skirmish
}

cmd_thumb() {
  # THUMB_SHOT (a full-size shot) and THUMB_CROP (w:h:x:y, a square of the 1920x1080 frame): the square scaled to the
  # mod portal's 144x144 thumbnail; the square at full resolution, web-encoded, is docs/media/thumbnail-source.png
  local shot="$FULL/${THUMB_SHOT:-13-commander-abilities.png}" sq="$SHOW/thumbnail-source.png"
  [ -f "$shot" ] || { echo "showcase: no $shot"; exit 1; }
  ffmpeg -v error -y -i "$shot" -vf "crop=${THUMB_CROP:-640:640:560:250}" "$sq"
  ffmpeg -v error -y -i "$sq" -vf "scale=144:144:flags=lanczos" "$RTS_ROOT/mods/factorio-rts/thumbnail.png"
  sips -g pixelWidth -g pixelHeight "$RTS_ROOT/mods/factorio-rts/thumbnail.png" | tail -2
  web "$sq" thumbnail-source
}

cmd_web() {
  local f n=0
  if [ $# -eq 0 ]; then
    for f in "$FULL"/*.png; do [ -f "$f" ] && web "$f" && n=$(( n + 1 )); done
  else
    for f in "$@"; do web "$FULL/${f%.png}.png" && n=$(( n + 1 )); done
  fi
  [ -f "$SHOW/thumbnail-source.png" ] && [ $# -eq 0 ] && web "$SHOW/thumbnail-source.png" thumbnail-source
  echo "showcase: $n web version(s) in docs/media/ ($(du -sh "$MEDIA" | cut -f1) in all)"
}

case "${1:-}" in
  all) cmd_lobby; cmd_bake; cmd_nation; cmd_skirmish; cmd_thumb ;;
  lobby) shift; cmd_lobby "$@" ;;
  bake) cmd_bake ;;
  nation) shift; cmd_nation "$@" ;;
  skirmish) shift; cmd_skirmish "$@" ;;
  thumb) cmd_thumb ;;
  web) shift; cmd_web "$@" ;;
  full) ls -l "$FULL" ;;
  crop) crop "${2:?launch}" ;;
  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
