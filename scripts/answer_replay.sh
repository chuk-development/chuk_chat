#!/usr/bin/env bash
# Draws real answers through the real MessageBubble, headless, one PNG each.
# Usage: scripts/answer_replay.sh [--light] [--width 430] <messages.json> <out dir>
# The window runs under its own Xvfb, never on the owner's screen.
set -euo pipefail
cd "$(dirname "$0")/.."

light=false
width=430
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --light) light=true; shift ;;
    --width) width="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ $# -eq 2 ]] || { echo "usage: $0 [--light] [--width N] <messages.json> <out dir>" >&2; exit 2; }

# A taller screen keeps Flutter from clipping the repaint boundary.
# Own data dir: the replay needs no app data and must not touch the real one.
export XDG_DATA_HOME="$PWD/_scratch/answer_replay_xdg"
mkdir -p "$XDG_DATA_HOME"
CHUK_MULTI_INSTANCE=1 exec xvfb-run -a -s "-screen 0 1600x8000x24" \
  flutter run -d linux --debug -t lib/dev/answer_replay_main.dart \
  --dart-define=REPLAY_FILE="$(realpath "$1")" \
  --dart-define=REPLAY_OUT="$(realpath -m "$2")" \
  --dart-define=REPLAY_WIDTH="$width" \
  --dart-define=REPLAY_LIGHT="$light"
