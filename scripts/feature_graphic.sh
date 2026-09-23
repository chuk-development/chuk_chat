#!/usr/bin/env bash
# Build the Play feature graphic (1024x500) for every locale.
#
# The graphic is the banner behind the listing title. It shows the wordmark,
# the slogan and one real screenshot of the app, on the brand background.
# Only ImageMagick is needed; the screenshot comes from
# fastlane/screenshots_raw/<locale>/01_chat.png.
#
# Usage: ./scripts/feature_graphic.sh [locale]

set -euo pipefail

BG_TOP="#111318"
BG_BOTTOM="#1D2433"
ACCENT="#D97757"        # the app's shipped accent
FG="#E2E2E9"            # kDefaultIconFgColor
MUTED="#9BA1AC"
FONT_BOLD="assets/fonts/Merriweather-Bold.ttf"
FONT_TEXT="assets/fonts/Arimo-wght.ttf"
W=1024
H=500

command -v convert >/dev/null 2>&1 || {
  echo "ImageMagick is missing: sudo apt install imagemagick" >&2
  exit 1
}

build_one() {
  local locale="$1" tagline="$2" sub="$3"
  local shot="fastlane/screenshots_raw/$locale/01_chat.png"
  local out="fastlane/metadata/android/$locale/images/featureGraphic.png"
  local tmp
  tmp="$(mktemp -d)"

  convert -size "${W}x${H}" "gradient:${BG_TOP}-${BG_BOTTOM}" \
    -fill "$ACCENT" -colorize 5% "$tmp/bg.png"

  # The screenshot sits on the right, cropped to its top half — the chat
  # header and the first answer are what a browsing user recognises.
  if [ -f "$shot" ]; then
    convert "$shot" -resize 'x760' -gravity north -crop '390x420+0+0' +repage \
      "$tmp/shot.png"
    local sw sh
    sw=$(identify -format '%w' "$tmp/shot.png")
    sh=$(identify -format '%h' "$tmp/shot.png")
    convert -size "${sw}x${sh}" xc:black -fill white \
      -draw "roundrectangle 0,0 $((sw-1)),$((sh-1)) 28,28" "$tmp/mask.png"
    convert "$tmp/shot.png" "$tmp/mask.png" -alpha Set -compose DstIn \
      -composite "$tmp/rounded.png"
    convert "$tmp/rounded.png" \
      -fill none -stroke "$ACCENT" -strokewidth 2 \
      -draw "roundrectangle 1,1 $((sw-2)),$((sh-2)) 28,28" "$tmp/edged.png"
    convert "$tmp/edged.png" \
      \( +clone -background black -shadow 60x18+0+10 \) \
      +swap -background none -layers merge +repage "$tmp/device.png"
    convert "$tmp/bg.png" "$tmp/device.png" \
      -gravity east -geometry +70+40 -compose over -composite "$tmp/stage.png"
  else
    echo "missing capture: $shot" >&2
    echo "run scripts/device_screenshots.sh first." >&2
    rm -rf "$tmp"
    return 1
  fi

  convert "$tmp/stage.png" \
    -font "$FONT_BOLD" -pointsize 68 -fill "$FG" \
    -annotate +72+215 'Chuk Chat' \
    -font "$FONT_TEXT" -pointsize 30 -fill "$ACCENT" \
    -annotate +74+265 "$tagline" \
    -font "$FONT_TEXT" -pointsize 22 -fill "$MUTED" \
    -annotate +74+310 "$sub" \
    "$out"

  rm -rf "$tmp"
  echo "wrote $out"
}

case "${1:-all}" in
  en-US) build_one en-US "Private and Secure. Always." "Encrypted AI chat on open-weight models" ;;
  de-DE) build_one de-DE "Private and Secure. Always." "Verschlüsselter KI-Chat mit offenen Modellen" ;;
  all)
    build_one en-US "Private and Secure. Always." "Encrypted AI chat on open-weight models"
    build_one de-DE "Private and Secure. Always." "Verschlüsselter KI-Chat mit offenen Modellen"
    ;;
  *) echo "unknown locale: $1" >&2; exit 1 ;;
esac
