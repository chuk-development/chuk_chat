#!/usr/bin/env bash
# Start the chuk-voice LiveKit worker.
#
#   ./run.sh dev     development mode
#   ./run.sh start   production mode
#   ./run.sh <any>   other LiveKit CLI commands (e.g. download-files)
#
# Extra arguments go to the LiveKit CLI, e.g. `./run.sh dev --log-level info`.
#
# The worker holds no provider keys. It needs only LIVEKIT_URL,
# LIVEKIT_API_KEY, LIVEKIT_API_SECRET (and optionally CHUK_API_BASE), from
# agents/voice/.env.local or from the environment (e.g. a systemd unit).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

if [[ ! -f "$here/.env.local" ]]; then
  for var in LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET; do
    if [[ -z "${!var:-}" ]]; then
      echo "run.sh: $var is not set. Create $here/.env.local (see README.md)." >&2
      exit 1
    fi
  done
fi
# new-voicemode listens on 8083; keep clear of it.
export VOICE_HEALTH_PORT="${VOICE_HEALTH_PORT:-8093}"

cmd="${1:-dev}"
[[ $# -gt 0 ]] && shift

echo "run.sh: health port $VOICE_HEALTH_PORT" >&2
case "$cmd" in
  dev)
    uv sync
    exec uv run agent.py dev "$@"
    ;;
  start)
    uv sync --no-dev
    exec uv run --no-dev agent.py start "$@"
    ;;
  *)
    uv sync
    exec uv run agent.py "$cmd" "$@"
    ;;
esac
