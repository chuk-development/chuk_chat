#!/usr/bin/env bash
# Starts the app against the local E2E stack, walks the screens of a walk
# file through the agent driver and writes screenshots to _scratch/verify/.
# See docs/AGENT_DRIVER.md and docs/VERIFICATION.md.
#
#   scripts/verify_ui.sh                      # default walk (sign in, chat)
#   scripts/verify_ui.sh my_walk.json         # your own walk file
#   scripts/verify_ui.sh --headed             # show the window on the desktop
#
# The app gets its own data folders under _scratch/agent_home and
# CHUK_MULTI_INSTANCE=1 (tool/agent_driver/src/isolation.dart). It never
# uses the data folders of the installed app.
#
# The script does not start or stop the stack. Start it first:
#   E2E_EMULATOR_PORT=8797 scripts/e2e_stack.sh up

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WALK="tool/agent_driver/walks/smoke.json"
EXTRA=()
for arg in "$@"; do
  case "$arg" in
    --headed) EXTRA+=(--headed) ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) WALK="$arg" ;;
  esac
done

DEFINES="_scratch/e2e.defines.json"
[ -f "$DEFINES" ] || {
  echo "verify_ui: no $DEFINES. Start the stack: E2E_EMULATOR_PORT=8797 scripts/e2e_stack.sh up" >&2
  exit 2
}
[ -f "$WALK" ] || { echo "verify_ui: no walk file $WALK" >&2; exit 2; }

# The API emulator port comes from the defines file.
api_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["API_BASE_URL"])' "$DEFINES")"
if ! curl -fsS -o /dev/null --max-time 5 "$api_url/v1/models_info"; then
  echo "verify_ui: the API emulator at $api_url does not answer. Start the stack first." >&2
  exit 2
fi

OUT="_scratch/verify"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "verify_ui: walk $WALK -> $OUT/"
dart run tool/agent_driver/bin/agent_driver.dart \
  --script "$WALK" --shots "$OUT" "${EXTRA[@]}"

shopt -s nullglob
pngs=("$OUT"/*.png)
if [ "${#pngs[@]}" -eq 0 ]; then
  echo "verify_ui: the walk wrote no screenshots. A UI task needs one (docs/VERIFICATION.md)." >&2
  exit 1
fi
echo "verify_ui: screenshots:"
printf '%s\n' "${pngs[@]}"
echo "verify_ui: open each PNG and check it against the task."
