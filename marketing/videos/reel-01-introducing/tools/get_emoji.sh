#!/usr/bin/env bash
# Download the Microsoft Fluent 3D emoji this reel uses (MIT licence).
# Source: https://github.com/microsoft/fluentui-emoji  (assets/<Name>/3D/<slug>_3d.png)
set -uo pipefail
cd "$(dirname "$0")/.." >/dev/null
BASE="https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/assets"
mkdir -p assets/emoji
while IFS='|' read -r name slug; do
  [ -z "$name" ] && continue
  out="assets/emoji/${slug}.png"
  [ -s "$out" ] && continue
  url="$BASE/$(printf '%s' "$name" | sed 's/ /%20/g')/3D/${slug}_3d.png"
  code=$(curl -sL -w '%{http_code}' -o "$out" "$url")
  if [ "$code" != "200" ]; then echo "MISS $name ($code)"; rm -f "$out"; else echo "ok   $slug"; fi
done <<'LIST'
Laptop|laptop
Spiral calendar|spiral_calendar
Envelope|envelope
World map|world_map
Bar chart|bar_chart
Locked|locked
Receipt|receipt
Mobile phone|mobile_phone
Artist palette|artist_palette
Speech balloon|speech_balloon
Magnifying glass tilted left|magnifying_glass_tilted_left
Globe with meridians|globe_with_meridians
Memo|memo
Chart increasing|chart_increasing
Framed picture|framed_picture
Page facing up|page_facing_up
Round pushpin|round_pushpin
Key|key
Light bulb|light_bulb
Books|books
Hot beverage|hot_beverage
Pencil|pencil
Clipboard|clipboard
File folder|file_folder
Camera|camera
Package|package
Compass|compass
Sparkles|sparkles
Open book|open_book
Headphone|headphone
Paperclip|paperclip
Shield|shield
Alarm clock|alarm_clock
LIST
