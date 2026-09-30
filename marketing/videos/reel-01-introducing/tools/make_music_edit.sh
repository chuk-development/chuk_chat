#!/usr/bin/env bash
# Build assets/bgm/track_edit.wav from the supplied track only (no generation).
# Source: marketing/_shared/music/05-announce-yourself.wav (MP3 data with a .wav
# name), transcoded to assets/bgm/track.wav (PCM, 48 kHz).
# 120 BPM, bars 2.0 s, source downbeats at 0.069 + 2k s.
# One straight cut, no splice: source 7.069 -> 66.769 = video 0 -> 59.70.
#   video 0-1     intro tail with the pickup   (source 7.07-8.07)
#   video 1       first kick                   -> the icon burst
#   video 1-9     half-time groove             -> Introducing, kinetic headline
#   video 9-15    full groove + riser 1        -> "Many worlds", week chat
#   video 15-17   break                        -> "Checking Linear/Todoist/Notion"
#   video 17      DROP (source 24.07)          -> the plan card lands
#   video 31-32.5 break                        -> "Now email it to her."
#   video 33      groove returns               -> the email card lands
#   video 41-49   breakdown                    -> Android assistant
#   video 49-55   groove + riser 2             -> Connect your apps, "AI that" 3
#   video 55-57   break                        -> end-card build
#   video 57-59.7 last hit + ring-out          -> end card hold
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
SRC_SHARED=/home/user/git/chuk_chat/marketing/_shared/music/05-announce-yourself.wav
[ -s assets/bgm/track.wav ] || ffmpeg -hide_banner -loglevel error -y -i "$SRC_SHARED" -c:a pcm_s16le -ar 48000 assets/bgm/track.wav
ffmpeg -hide_banner -loglevel error -y -i assets/bgm/track.wav -af \
  "atrim=start=7.069:end=66.769,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.08,afade=t=out:st=59.2:d=0.5" \
  -c:a pcm_s16le -ar 48000 assets/bgm/track_edit.wav
ffprobe -v error -show_entries format=duration -of default=nw=1 assets/bgm/track_edit.wav
