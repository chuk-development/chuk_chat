#!/usr/bin/env bash
# Build assets/bgm/track_edit.wav from the supplied track only.
# Segments (source seconds): A 7.069-48.069, B 56.069-64.069, C 24.069-36.069.
# 30 ms crossfades at the splices, 0.35 s fade-in, 4 s fade-out, 61.0 s long.
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
SRC=assets/bgm/track.wav
OUT=assets/bgm/track_edit.wav
ffmpeg -hide_banner -loglevel error -y -i "$SRC" -i "$SRC" -i "$SRC" -filter_complex "
[0:a]atrim=start=7.069:end=48.099,asetpts=PTS-STARTPTS[a];
[1:a]atrim=start=56.069:end=64.099,asetpts=PTS-STARTPTS[b];
[2:a]atrim=start=24.069:end=36.069,asetpts=PTS-STARTPTS[c];
[a][b]acrossfade=d=0.03:c1=tri:c2=tri[ab];
[ab][c]acrossfade=d=0.03:c1=tri:c2=tri[abc];
[abc]afade=t=in:st=0:d=0.35,afade=t=out:st=57:d=4,atrim=end=61,apad=whole_dur=61[out]" -map "[out]" -c:a pcm_s16le -ar 48000 "$OUT"
ffprobe -v error -show_entries format=duration -of default=nw=1 "$OUT"
