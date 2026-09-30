#!/usr/bin/env bash
# Pull full-resolution review frames out of a rendered reel (not tiles):
# title, prompt + dots, answer + card, the swipe, full-screen result, end tag.
# Usage: tools/frames.sh <slug> [seconds...]   -> _work/frames/<slug>/t<sec>.png
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
slug=$1; shift || true
times=("$@"); [[ ${#times[@]} -eq 0 ]] && times=(1.0 3.5 5.3 8.0 9.25 10.5 11.9)
src=../../out/reels/ask-${slug}_nomusic.mp4
out=_work/frames/$slug; rm -rf "$out"; mkdir -p "$out"
for t in "${times[@]}"; do ffmpeg -v error -y -ss "$t" -i "$src" -frames:v 1 "$out/t$t.png"; done
ls "$out"
