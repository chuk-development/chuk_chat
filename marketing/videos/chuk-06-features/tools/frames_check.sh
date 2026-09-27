#!/usr/bin/env bash
# Pull one full-resolution frame per beat from the render (readability check).
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
mkdir -p _work/check
for t in 0.3 3.6 7.6 11.6 15.6 19.6 23.6 27.6 31.6 35.6 39.6 43.6 47.6 51.6 55.6 57.5 62.5; do
  ffmpeg -hide_banner -loglevel error -y -ss "$t" -i renders/video.mp4 -frames:v 1 "_work/check/f_${t}.png"
done
ffmpeg -hide_banner -loglevel error -y -i renders/video.mp4 -vf fps=1,scale=480:-1,tile=8x8 -frames:v 1 _work/sheet.jpg
ls _work/check
