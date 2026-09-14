#!/usr/bin/env bash
# Put raw phone captures on a branded background, inside a rounded device body.
#
# The Play listing shows the screenshots small, side by side. A raw capture
# reads as a grey rectangle there; a framed one reads as a phone. This script
# needs only ImageMagick, not fastlane frameit and its frame packs.
#
# Usage:
#   ./scripts/frame_screenshots.sh            # every locale
#   ./scripts/frame_screenshots.sh en-US      # one locale
#
# Input:  fastlane/screenshots_raw/<locale>/*.png   (the raw device captures)
# Output: fastlane/metadata/android/<locale>/images/phoneScreenshots/*.png
#
# The raw captures stay outside the metadata tree, so a re-run always frames
# the original capture and never a framed image, and neither `supply` nor
# F-Droid sees a second copy of every screenshot.

set -euo pipefail

BG_TOP="#111318"       # kDefaultBgColor
BG_BOTTOM="#1D2433"    # a touch lighter, so the background is not flat
ACCENT="#A8C7FA"       # kDefaultAccentColor
OUT_W=1080
OUT_H=1920
MARGIN=64              # space between the canvas edge and the device body
RADIUS=48              # corner radius of the device body

command -v convert >/dev/null 2>&1 || {
  echo "ImageMagick is missing: sudo apt install imagemagick" >&2
  exit 1
}

frame_one() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp -d)"

  # The device body: the capture scaled to fit, with rounded corners.
  local body_w=$(( OUT_W - 2 * MARGIN ))
  local body_h=$(( OUT_H - 2 * MARGIN ))

  convert "$src" -resize "${body_w}x${body_h}" "$tmp/shot.png"
  local w h
  w=$(identify -format '%w' "$tmp/shot.png")
  h=$(identify -format '%h' "$tmp/shot.png")

  convert -size "${w}x${h}" xc:black -fill white \
    -draw "roundrectangle 0,0 $((w-1)),$((h-1)) $RADIUS,$RADIUS" \
    "$tmp/mask.png"
  convert "$tmp/shot.png" "$tmp/mask.png" \
    -alpha Set -compose DstIn -composite "$tmp/rounded.png"

  # The background: a vertical brand gradient with a soft accent glow.
  convert -size "${OUT_W}x${OUT_H}" \
    "gradient:${BG_TOP}-${BG_BOTTOM}" "$tmp/bg.png"
  convert "$tmp/bg.png" \
    -fill "$ACCENT" -colorize 6% "$tmp/bg_tinted.png"

  # A thin accent hairline around the body reads as the device edge, and a
  # soft shadow lifts it off the background.
  convert "$tmp/rounded.png" \
    -fill none -stroke "$ACCENT" -strokewidth 3 \
    -draw "roundrectangle 1,1 $((w-2)),$((h-2)) $RADIUS,$RADIUS" \
    "$tmp/edged.png"
  convert "$tmp/edged.png" \
    \( +clone -background black -shadow 55x24+0+12 \) \
    +swap -background none -layers merge +repage "$tmp/body.png"

  convert "$tmp/bg_tinted.png" "$tmp/body.png" \
    -gravity center -compose over -composite "$dst"

  rm -rf "$tmp"
}

frame_locale() {
  local locale="$1"
  local raw="fastlane/screenshots_raw/$locale"
  local out="fastlane/metadata/android/$locale/images/phoneScreenshots"
  [ -d "$raw" ] || {
    # Silence here would leave the old listing images in place and look like
    # success — exactly how a misspelled locale ships a stale screenshot.
    echo "no raw captures in $raw" >&2
    return 1
  }

  local captures=()
  shopt -s nullglob
  captures=("$raw"/*.png)
  shopt -u nullglob
  if [ "${#captures[@]}" -eq 0 ]; then
    # Without this the cleanup below would wipe the whole listing and call it
    # a success. The output directory is created only after this check, so a
    # bad locale name cannot leave an empty listing folder behind either.
    echo "no PNG captures in $raw" >&2
    return 1
  fi
  mkdir -p "$out"

  # The listing folder mirrors the raw folder. A capture that was renamed or
  # dropped must not leave its old image behind, or `supply` uploads a
  # screenshot of a screen that no longer exists.
  for old in "$out"/*.png; do
    [ -e "$old" ] || continue
    if [ ! -e "$raw/$(basename "$old")" ]; then
      rm -f "$old"
      echo "removed stale $old"
    fi
  done

  local count=0
  for src in "${captures[@]}"; do
    local name
    name="$(basename "$src")"
    frame_one "$src" "$out/$name"
    echo "framed $out/$name"
    count=$((count + 1))
  done
  echo "$locale: $count image(s)"
}

if [ "$#" -ge 1 ]; then
  frame_locale "$1"
else
  shopt -s nullglob
  locales=(fastlane/screenshots_raw/*/)
  shopt -u nullglob
  if [ "${#locales[@]}" -eq 0 ]; then
    echo "no locales under fastlane/screenshots_raw/" >&2
    exit 1
  fi
  for dir in "${locales[@]}"; do
    frame_locale "$(basename "$dir")"
  done
fi
