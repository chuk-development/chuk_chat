#!/usr/bin/env bash
# Render one reel into both deliverables.
#   ./render.sh <slug> [--draft]
# -> marketing/out/reels/ask-<slug>_nomusic.mp4  (silent picture, owner adds IG audio)
# -> marketing/out/reels/ask-<slug>.mp4          (same picture + music bed)
# The picture is rendered once through the shared render lock; the bed is muxed on
# with ffmpeg (stream copy of the video, so both files carry identical frames).
set -euo pipefail
cd "$(dirname "$0")" >/dev/null
slug=${1:?usage: ./render.sh <slug> [--draft]}
quality=high
[[ ${2:-} == --draft ]] && quality=draft
OUT=$(cd ../../out && pwd)/reels
LOCK=/home/user/git/chuk_chat/marketing/_shared/.render.lock
mkdir -p "$OUT"

python3 tools/build.py "$slug"
flock "$LOCK" npx hyperframes render -c "compositions/ask-$slug.html" --quality "$quality" \
  -o "$OUT/ask-${slug}_nomusic.mp4"

dur=$(python3 -c "import json,sys; sys.path.insert(0,'tools'); import build; r=json.load(open('reels/$slug.json')); print(r.get('timing',{}).get('duration', build.DEFAULTS['duration']))")
bed=$(bash tools/make_bed.sh "$dur")
ffmpeg -v error -y -i "$OUT/ask-${slug}_nomusic.mp4" -i "$bed" -map 0:v:0 -map 1:a:0 \
  -c:v copy -c:a aac -b:a 192k -ar 48000 -t "$dur" -movflags +faststart "$OUT/ask-$slug.mp4"
echo "done: $OUT/ask-$slug.mp4 and $OUT/ask-${slug}_nomusic.mp4 (${dur}s)"
