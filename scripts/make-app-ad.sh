#!/usr/bin/env bash
# make-app-ad <name> [backdrop]
#
# Put the running Chuk Chat desktop window on a painted backdrop, at 4K.
#
# The raw window grab reads as a grey rectangle on a landing page or a social
# post. The same grab on a painting, with rounded corners and a soft shadow,
# reads as a product shot. This is the marketing image, not the store listing
# image — scripts/frame_screenshots.sh makes those, from phone captures.
#
# Usage:
#   ./scripts/make-app-ad.sh home_ui
#   ./scripts/make-app-ad.sh home_ui scripts/backdrops/debat-ponsan.jpg
#
# The app must already run on X11 and show the screen you want. Start it with
# ./run-hot.sh linux; a Wayland window has no X11 id and xdotool cannot find it.
#
# The grab takes whatever the window shows, and the chats on screen are
# decrypted. This repository is public, and docs/screenshots/ads is committed,
# so the session in the frame must hold nothing private: sign in with a
# throwaway account, or start a fresh chat and ask only demo questions. Keep
# the sidebar closed — it lists real chat titles — and stay out of the account
# pages, which show the name and the e-mail address.
#
# Output: docs/screenshots/ads/screenshot_<name>.png   (3840x2160)
# Raw:    _scratch/app_ads_raw/<name>.png              (gitignored)

set -euo pipefail

NAME="${1:?usage: make-app-ad <name> [backdrop]}"
# The name becomes a file name in two directories. A name carrying a path
# would write outside them and could overwrite an unrelated PNG.
case "$NAME" in
  *[!A-Za-z0-9_-]* | '')
    echo "name must be letters, digits, '-' or '_': $NAME" >&2
    exit 1
    ;;
esac
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BG="${2:-$REPO/scripts/backdrops/debat-ponsan.jpg}"
OUT_DIR="$REPO/docs/screenshots/ads"
RAW_DIR="$REPO/_scratch/app_ads_raw"

command -v xdotool >/dev/null 2>&1 || { echo "xdotool is missing: sudo apt install xdotool" >&2; exit 1; }
# Both ImageMagick tools are checked, not only convert: `import` needs the X11
# delegate, which some packages leave out. Without this the window is grabbed
# and the run dies at the first composite, after the moment has passed.
for tool in import convert; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ImageMagick '$tool' is missing: sudo apt install imagemagick" >&2
    exit 1
  }
done
[ -f "$BG" ] || { echo "backdrop not found: $BG" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$RAW_DIR"

# The window title is exact, so a browser tab called "Chuk Chat" is never
# captured instead of the app.
CHUK_ID="$(xdotool search --name '^Chuk Chat$' | head -1 || true)"
[ -n "$CHUK_ID" ] || {
  echo "No Chuk Chat window. Start it with ./run-hot.sh linux (X11, not Wayland)." >&2
  exit 1
}

# The capture is committable and the repository is public, so the warning goes
# on screen every run, not only into this header.
echo "The grab shows the live window. Private chats, names and e-mail" >&2
echo "addresses in the frame end up in a public repository." >&2

xdotool windowactivate "$CHUK_ID"
# The pointer parks in the corner, or a hover highlight lands in the image.
xdotool mousemove 0 0
sleep 0.6

RAW="$RAW_DIR/${NAME}.png"
import -window "$CHUK_ID" +repage "$RAW"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The backdrop fills 4K; the window sits on it at 3360x1890, so the painting
# stays visible as a border on every side.
convert "$BG" -resize 3840x2160^ -gravity center -extent 3840x2160 "$TMP/bg.png"
convert "$RAW" -filter Lanczos -resize 3360x1890 \
  \( +clone -alpha extract \
     -draw 'fill black polygon 0,0 12,0 0,12 fill white circle 12,12 12,0' \
     \( +clone -flip \) -compose Multiply -composite \
     \( +clone -flop \) -compose Multiply -composite \) \
  -alpha off -compose CopyOpacity -composite "$TMP/sr.png"
convert "$TMP/sr.png" \( +clone -background black -shadow 70x50+0+0 \) \
  +swap -background none -layers merge +repage "$TMP/srs.png"
convert "$TMP/bg.png" "$TMP/srs.png" -gravity center -composite "$OUT_DIR/screenshot_${NAME}.png"

echo "saved $OUT_DIR/screenshot_${NAME}.png"
