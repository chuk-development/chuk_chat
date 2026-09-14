#!/usr/bin/env bash
# Capture the README screenshots of the Linux app on a virtual display.
#
# Why a virtual display: an X11 capture of the real desktop returns black
# whenever the monitor is asleep, and it also drags the user's own windows
# into the frame. Xvfb gives a clean 1600x1000 screen that is always awake.
#
# These captures are committed into assets/screenshots/ and end up in the
# README, so the account in the frame must hold nothing private: sign in with
# a throwaway account, or clear the chat list first, and ask only demo
# questions. Keep the sidebar collapsed — it lists real chat titles — and stay
# out of the account pages, which show the name and the e-mail address.
#
# Usage:
#   ./scripts/desktop_screenshots.sh start        # launch the release build at 2400x1350
#   ./scripts/desktop_screenshots.sh shot <name>  # write _scratch/desktop_raw/<name>.png
#   ./scripts/desktop_screenshots.sh type "text"  # type into the app
#   ./scripts/desktop_screenshots.sh key Return
#   ./scripts/desktop_screenshots.sh webp         # convert every shot into assets/screenshots/
#   ./scripts/desktop_screenshots.sh stop

set -euo pipefail

DISP="${SCREENSHOT_DISPLAY:-:99}"
# The README images are 2400x1350. The virtual screen is a little larger so the
# window manager has room for the frame it draws; the capture takes the window
# itself, so no title bar and no desktop ever reach the image.
WIN_W="${SCREENSHOT_WIDTH:-2400}"
WIN_H="${SCREENSHOT_HEIGHT:-1350}"
TITLEBAR="${SCREENSHOT_TITLEBAR:-37}"   # metacity's frame, measured once
GEOMETRY="${SCREENSHOT_GEOMETRY:-${WIN_W}x$((WIN_H + TITLEBAR))x24}"
BUNDLE="build/linux/x64/release/bundle/chuk_chat"
RAW_DIR="_scratch/desktop_raw"
OUT_DIR="assets/screenshots"
# One file per display holds the PIDs this script started, so `stop` and the
# failure cleanup signal those processes only — never another capture session
# and never an app the user started by hand.
PID_FILE="_scratch/desktop_screenshots${DISP//[^0-9]/}.pids"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }
}

# Every wait is bounded: a failed Xvfb, an app that dies at startup or a
# different window title must end the run with an error, not hang the caller.
wait_for() {
  local what="$1" limit="$2"; shift 2
  local waited=0
  until "$@" >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$limit" ]; then
      echo "gave up waiting for $what after ${limit}s" >&2
      exit 1
    fi
  done
}

window_is_up() {
  DISPLAY="$DISP" wmctrl -l | grep -q "Chuk Chat"
}

app_window() {
  DISPLAY="$DISP" xdotool search --onlyvisible --name "Chuk Chat" | head -n1
}

# Clicks are given in the coordinates of the captured image, which is the
# window itself. The window manager places the window somewhere on the virtual
# screen, so its origin has to be added or every click lands in the wrong spot.
click_in_window() {
  local x="$1" y="$2" id geom win_x win_y
  id="$(app_window)"
  [ -n "$id" ] || { echo "no Chuk Chat window on $DISP" >&2; return 1; }
  # xwininfo, not `xdotool getwindowgeometry`: xdotool adds the window
  # manager's frame height a second time, which puts every click one title bar
  # too low.
  geom="$(DISPLAY="$DISP" xwininfo -id "$id")"
  win_x="$(printf '%s\n' "$geom" | sed -n 's/.*Absolute upper-left X: *//p')"
  win_y="$(printf '%s\n' "$geom" | sed -n 's/.*Absolute upper-left Y: *//p')"
  DISPLAY="$DISP" xdotool windowactivate --sync "$id"
  DISPLAY="$DISP" xdotool mousemove $(( win_x + x )) $(( win_y + y )) click 1
}

# Anything this run started is torn down again when the run fails. Processes
# that were already up stay up: a second capture session must not kill the
# first one's display.
remember_pid() {
  local pid="$1"
  mkdir -p "$(dirname "$PID_FILE")"
  # The start time pins the identity of the process. Linux reuses PIDs, and a
  # stale file must never make this script kill somebody else's process.
  local started
  started="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
  echo "$pid $started" >> "$PID_FILE"
}

kill_remembered() {
  [ -f "$PID_FILE" ] || return 0
  local pid started now
  while read -r pid started; do
    [ -n "$pid" ] || continue
    now="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo "")"
    if [ -n "$now" ] && [ "$now" = "$started" ]; then
      kill "$pid" 2>/dev/null
    fi
  done < "$PID_FILE"
  rm -f "$PID_FILE"
}

cleanup_on_failure() {
  kill_remembered
  return 0
}

start() {
  need Xvfb; need xdpyinfo; need xdotool; need import; need wmctrl; need xwininfo
  need metacity
  if [ -e "$PID_FILE" ]; then
    # A second session on the same display would orphan the first one's
    # processes: `stop` only knows the PIDs in this file.
    echo "a capture session already owns $DISP — run 'stop' first," >&2
    echo "or set SCREENSHOT_DISPLAY to another display." >&2
    exit 1
  fi
  trap cleanup_on_failure EXIT

  if ! DISPLAY="$DISP" xdpyinfo >/dev/null 2>&1; then
    nohup Xvfb "$DISP" -screen 0 "$GEOMETRY" >/dev/null 2>&1 &
    remember_pid "$!"
    wait_for "Xvfb on $DISP" 30 env DISPLAY="$DISP" xdpyinfo
    echo "started Xvfb on $DISP ($GEOMETRY)"
  fi

  # A window manager is what makes the window maximise; without one the app
  # opens at its default size in the corner.
  # wmctrl reads the EWMH client list, which only a window manager publishes.
  # Without one the window is never found and the wait below would time out.
  # A display that already has a window manager keeps it — `--replace` on a
  # real desktop would throw the user's own window manager out.
  if DISPLAY="$DISP" wmctrl -m >/dev/null 2>&1; then
    echo "using the window manager already on $DISP"
  else
    DISPLAY="$DISP" nohup metacity >/dev/null 2>&1 &
    remember_pid "$!"
    wait_for "a window manager on $DISP" 15 env DISPLAY="$DISP" wmctrl -m
  fi

  [ -x "$BUNDLE" ] || {
    echo "no release bundle — run:" >&2
    echo "  flutter build linux --release --dart-define-from-file=.env" >&2
    exit 1
  }

  DISPLAY="$DISP" nohup "$BUNDLE" >/dev/null 2>&1 &
  remember_pid "$!"
  wait_for "the app window" 60 window_is_up
  sleep 6
  # Maximise, and let the virtual screen decide the size: the screen is exactly
  # the target size plus the window manager's title bar, so the client area —
  # which is what gets captured — comes out at WIN_W x WIN_H. Resizing the
  # window after the engine has started leaves Flutter's hit testing on the old
  # size, and every click then lands in the wrong place.
  DISPLAY="$DISP" wmctrl -r "Chuk Chat" -b add,maximized_vert,maximized_horz
  sleep 2
  # The session survives on purpose — `shot`, `type` and `key` run against it
  # as separate commands, and `stop` ends it.
  trap - EXIT
  echo "app is up on $DISP"
}

shot() {
  local name="${1:?usage: shot <name>}"
  mkdir -p "$RAW_DIR"
  # The app window only, never the whole screen: another window on this
  # display would end up in a committed screenshot.
  local window_id
  window_id="$(DISPLAY="$DISP" xdotool search --onlyvisible --name "Chuk Chat" \
    | head -n1)"
  [ -n "$window_id" ] || {
    echo "no Chuk Chat window on $DISP — run 'start' first" >&2
    return 1
  }
  DISPLAY="$DISP" import -window "$window_id" "$RAW_DIR/$name.png"
  echo "wrote $RAW_DIR/$name.png"
}

to_webp() {
  need cwebp
  mkdir -p "$OUT_DIR"
  local captures=()
  shopt -s nullglob
  captures=("$RAW_DIR"/*.png)
  shopt -u nullglob
  if [ "${#captures[@]}" -eq 0 ]; then
    # Silence here would make a failed capture run look like a successful one.
    echo "no PNG captures in $RAW_DIR" >&2
    return 1
  fi
  for src in "${captures[@]}"; do
    local name
    name="$(basename "$src" .png)"
    cwebp -quiet -q 82 "$src" -o "$OUT_DIR/screenshot_$name.webp"
    echo "wrote $OUT_DIR/screenshot_$name.webp"
  done
}

case "${1:-}" in
  start) start ;;
  shot)  shift; shot "$@" ;;
  # No windowactivate here: re-activating the window takes the focus away from
  # the text field that was just clicked, and the keystrokes go nowhere. Click
  # into the field first, then type.
  type)  shift; DISPLAY="$DISP" xdotool type --delay 25 "$*" ;;
  key)   shift; DISPLAY="$DISP" xdotool key "$@" ;;
  click) shift; click_in_window "$1" "$2" ;;
  webp)  to_webp ;;
  stop)  kill_remembered
         echo "stopped" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
