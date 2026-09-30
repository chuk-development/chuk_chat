#!/usr/bin/env bash
# Build one reel and take review snapshots of it (index.html) into _work/snap/<slug>/.
# Usage: tools/snap.sh <slug> [comma-separated seconds]
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
slug=$1
at=${2:-1.0,3.0,3.8,5.2,7.0,8.8,9.25,10.5,11.8}
python3 tools/build.py "$slug" >/dev/null
out=_work/snap/$slug
rm -rf "$out"; mkdir -p "$out"
npx hyperframes snapshot --at "$at" --no-end -o "$out" >/dev/null 2>&1
mapfile -t f < <(ls "$out"/frame-*.png)
n=${#f[@]}; h=$(( (n + 1) / 2 ))
args=(); for x in "${f[@]:0:$h}"; do args+=(-i "$x"); done
ffmpeg -v error -y "${args[@]}" -filter_complex "hstack=$h,scale=$((400*h)):-1" "$out/row1.png"
args=(); for x in "${f[@]:$h}"; do args+=(-i "$x"); done
[[ $((n - h)) -gt 1 ]] && ffmpeg -v error -y "${args[@]}" -filter_complex "hstack=$((n-h)),scale=$((400*(n-h))):-1" "$out/row2.png"
echo "$out"
