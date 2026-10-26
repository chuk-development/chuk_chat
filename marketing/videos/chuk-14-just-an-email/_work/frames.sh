#!/bin/sh
# Decode full-size check frames from a final MP4: frames.sh <mp4> <outdir> <t1> <t2> ...
mp4="$1"; out="$2"; shift 2
mkdir -p "$out"
for t in "$@"; do
  ffmpeg -loglevel error -y -hwaccel cuda -ss "$t" -i "$mp4" -frames:v 1 "$out/f-$t.png"
done
