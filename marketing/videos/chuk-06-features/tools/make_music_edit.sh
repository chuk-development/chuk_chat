#!/usr/bin/env bash
# Build assets/bgm/track_edit.wav from the supplied track only (no generation).
# Source: marketing/_shared/music/05-announce-yourself.wav (MP3 data), transcoded
# to assets/bgm/track.wav (PCM). 120 BPM, source downbeats at 0.069 + 2k s.
# Segments (source seconds), every splice on a downbeat:
#   A 20.069-48.069 -> video  0-28  riser 1 tail, break V2-4, DROP 1 at V4, groove, break V18-20, groove
#   B 56.069-64.069 -> video 28-36  groove, riser 2 (V31.5-34), break with fill V34-36
#   C 24.069-52.069 -> video 36-64  DROP 2 at V36, groove, break V50-52, groove, breakdown from V60
# The B->C splice joins two identical breaks (62.07-64.07 == 22.07-24.07), so it is seamless.
# 30 ms crossfades at splices, 0.12 s fade-in, 4.5 s fade-out, 64.0 s long.
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
SRC=assets/bgm/track.wav
OUT=assets/bgm/track_edit.wav
ffmpeg -hide_banner -loglevel error -y -i "$SRC" -i "$SRC" -i "$SRC" -filter_complex "
[0:a]atrim=start=20.069:end=48.099,asetpts=PTS-STARTPTS[a];
[1:a]atrim=start=56.069:end=64.099,asetpts=PTS-STARTPTS[b];
[2:a]atrim=start=24.069:end=52.069,asetpts=PTS-STARTPTS[c];
[a][b]acrossfade=d=0.03:c1=tri:c2=tri[ab];
[ab][c]acrossfade=d=0.03:c1=tri:c2=tri[abc];
[abc]afade=t=in:st=0:d=0.12,afade=t=out:st=59.5:d=4.5,atrim=end=64,apad=whole_dur=64[out]" -map "[out]" -c:a pcm_s16le -ar 48000 "$OUT"
ffprobe -v error -show_entries format=duration -of default=nw=1 "$OUT"
