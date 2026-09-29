#!/usr/bin/env bash
# Start the chuk-voice LiveKit worker.
#
#   ./run.sh dev     development mode (hot reload, verbose)
#   ./run.sh start   production mode
#   ./run.sh <any>   other LiveKit CLI commands (e.g. download-files)
#
# Extra arguments go to the LiveKit CLI, e.g. `./run.sh dev --log-level info`.
#
# Env file: agents/voice/.env.local when it exists, else the new-voicemode
# worker's file. The file is read in place and never copied. Set
# VOICE_ENV_FILE to use another file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

fallback_env="/home/user/git/new-voicemode/server/.env.local"
if [[ -z "${VOICE_ENV_FILE:-}" ]]; then
  if [[ -f "$here/.env.local" ]]; then
    VOICE_ENV_FILE="$here/.env.local"
  elif [[ -f "$fallback_env" ]]; then
    VOICE_ENV_FILE="$fallback_env"
  else
    echo "run.sh: no env file. Create $here/.env.local (see README.md)." >&2
    exit 1
  fi
fi
export VOICE_ENV_FILE
# new-voicemode listens on 8083; keep clear of it.
export VOICE_HEALTH_PORT="${VOICE_HEALTH_PORT:-8093}"

cmd="${1:-dev}"
[[ $# -gt 0 ]] && shift

echo "run.sh: env file $VOICE_ENV_FILE, health port $VOICE_HEALTH_PORT" >&2
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
