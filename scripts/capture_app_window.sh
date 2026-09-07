#!/usr/bin/env bash
# Capture only a verified CoWork app window; never fall back to a desktop grab.
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
app_executable="$project_root/app/build/linux/x64/debug/bundle/cowork"
output_path="${1:-/tmp/cowork-window.png}"
best_window=''
best_pid=''
best_area=0
while read -r app_pid; do
  [[ "$(readlink -f "/proc/$app_pid/exe" 2>/dev/null || true)" == "$app_executable" ]] || continue
  while read -r window_id; do
    [[ "$window_id" =~ ^[0-9]+$ ]] || continue
    [[ "$(xdotool getwindowpid "$window_id" 2>/dev/null || true)" == "$app_pid" ]] || continue
    width=0
    height=0
    while IFS='=' read -r key value; do
      [[ "$value" =~ ^[0-9]+$ ]] || continue
      case "$key" in
        WIDTH) width="$value" ;;
        HEIGHT) height="$value" ;;
      esac
    done < <(xdotool getwindowgeometry --shell "$window_id" 2>/dev/null)
    area=$((width * height))
    if (( area > best_area && width >= 100 && height >= 100 )); then
      best_area="$area"
      best_window="$window_id"
      best_pid="$app_pid"
    fi
  done < <(xdotool search --onlyvisible --pid "$app_pid" 2>/dev/null || true)
done < <(pgrep -x cowork || true)
if [[ -z "$best_window" ]]; then
  echo 'No verified CoWork window. Start app with GDK_BACKEND=x11 via flutter-hot.' >&2
  exit 1
fi
# Recheck ownership immediately before capture, since window IDs can be reused.
[[ "$(xdotool getwindowpid "$best_window")" == "$best_pid" ]]
[[ "$(readlink -f "/proc/$best_pid/exe")" == "$app_executable" ]]
import -window "$best_window" "$output_path"
printf 'CoWork PID=%s window=%s capture=%s\n' "$best_pid" "$best_window" "$output_path"
