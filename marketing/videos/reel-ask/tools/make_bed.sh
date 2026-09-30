#!/usr/bin/env bash
# Cut the music bed for a reel of <dur> seconds from assets/bgm/track.wav.
# track.wav = marketing/_shared/music/01-introducing.wav (MP3 data) transcoded to PCM.
# Section: from 38.43 s, the drop into the loud part (the strongest 20 s of the track),
# so frame 0 already has the full beat. Bars at 0.08 + 2.4 n s: the phone lands on bar 2.
# 10 ms fade-in, 0.7 s fade-out. Prints the bed path.
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
dur=${1:?usage: make_bed.sh <seconds>}
start=38.43
out=assets/bgm/bed-${dur}s.wav
fo=$(python3 -c "print(round($dur - 0.7, 3))")
ffmpeg -v error -y -ss "$start" -t "$dur" -i assets/bgm/track.wav \
  -af "afade=t=in:st=0:d=0.01,afade=t=out:st=$fo:d=0.7,volume=0.9" -ar 48000 -ac 2 -c:a pcm_s16le "$out"
echo "$out"
