#!/usr/bin/env bash
# Measure CoWork on a real Android phone. Read-only: this script NEVER installs,
# uninstalls, force-updates or writes anything on the device. It starts the app
# that is already there, reads counters back out, and prints numbers.
#
# What it measures, and why each number matters:
#
#   1. Cold start (TotalTime / WaitTime from `am start -W`, after force-stop).
#      This is the demo: close the app, open it, be back in the conversation.
#      Five runs, median reported, because a single start is dominated by
#      whatever else the phone was doing that second.
#   2. Warm start: the same launch WITHOUT the force-stop, so the process is
#      still alive. The gap between cold and warm is what the launch path
#      itself costs, as opposed to the Android process start.
#   3. Jank while scrolling the chat, from `dumpsys gfxinfo`: the percentage of
#      janky frames plus the 50th / 90th / 95th / 99th percentile frame times.
#      A scroll that drops frames is what a customer sees as "it feels cheap",
#      and the percentiles say whether it is a constant cost or rare stalls.
#   4. Memory: TOTAL PSS from `dumpsys meminfo`. A phone kills the background
#      app that holds the most; a large PSS is why the "reopen and you are
#      back" demo turns into a cold start instead.
#
# Usage:
#   scripts/perf_phone.sh                 # all four measurements
#   scripts/perf_phone.sh --runs 9        # more start samples
#   scripts/perf_phone.sh --serial R5CT   # pick a device when several are up
#
# The app must already be installed and, for the scroll test, already open on a
# conversation with enough messages to scroll. Build and install with
# scripts/build_apk.sh; this script deliberately does not.
set -euo pipefail

PKG=dev.chuk.cowork
ACTIVITY="$PKG/.MainActivity"
RUNS=5
SERIAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="${2:?--runs needs a number}"; shift 2 ;;
    --serial) SERIAL="${2:?--serial needs a device id}"; shift 2 ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v adb >/dev/null 2>&1 || {
  echo "adb is not on PATH. Install the Android platform tools first." >&2
  exit 1
}

# `adb` runs every command; SERIAL selects a device when more than one is up.
adb_() {
  if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi
}

DEVICES="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
COUNT="$(printf '%s\n' "$DEVICES" | grep -c . || true)"
if [ "$COUNT" -eq 0 ]; then
  echo "No phone is attached, so there is nothing to measure." >&2
  echo "Plug the Pixel in over USB, allow the debugging prompt, then run this" >&2
  echo "again. Check with: adb devices" >&2
  exit 1
fi
if [ "$COUNT" -gt 1 ] && [ -z "$SERIAL" ]; then
  echo "More than one device is attached. Choose one with --serial:" >&2
  printf '  %s\n' $DEVICES >&2
  exit 1
fi
[ -n "$SERIAL" ] || SERIAL="$(printf '%s\n' "$DEVICES" | head -n1)"

adb_ shell pm path "$PKG" >/dev/null 2>&1 || {
  echo "$PKG is not installed on $SERIAL." >&2
  echo "This script only measures; install with scripts/build_apk.sh first." >&2
  exit 1
}

DEVICE_MODEL="$(adb_ shell getprop ro.product.model | tr -d '\r')"
ANDROID_REL="$(adb_ shell getprop ro.build.version.release | tr -d '\r')"
echo "device: $SERIAL ($DEVICE_MODEL, Android $ANDROID_REL)"
echo "package: $PKG   runs per start measurement: $RUNS"

# The median of the numbers on stdin. A median, not a mean: one background sync
# on the phone must not move the reported figure.
median() {
  sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { print "n/a"; exit }
      if (NR % 2) { print v[(NR + 1) / 2] }
      else { printf "%.1f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }
    }'
}

minmax() {
  sort -n | awk 'NR==1{min=$1} {max=$1} END{ if (NR) printf "%s..%s", min, max }'
}

# One `am start -W`, printing "<TotalTime> <WaitTime>". `am start -W` waits for
# the launch to report itself finished, so these are the device's own numbers,
# not a stopwatch around adb.
start_once() {
  adb_ shell am start -W -n "$ACTIVITY" 2>/dev/null | awk -F': *' '
    /^TotalTime:/ { total = $2 }
    /^WaitTime:/  { wait  = $2 }
    END { print total, wait }'
}

measure_starts() {
  local label="$1" cold="$2"
  local totals="" waits="" line
  for _ in $(seq 1 "$RUNS"); do
    if [ "$cold" = yes ]; then
      adb_ shell am force-stop "$PKG"
      sleep 2
    fi
    line="$(start_once)"
    totals="$totals${line%% *}"$'\n'
    waits="$waits${line##* }"$'\n'
    sleep 2
  done
  printf '%-18s TotalTime median %6s ms  (range %s)\n' \
    "$label" "$(printf '%s' "$totals" | grep . | median)" \
    "$(printf '%s' "$totals" | grep . | minmax)"
  printf '%-18s WaitTime  median %6s ms  (range %s)\n' \
    "" "$(printf '%s' "$waits" | grep . | median)" \
    "$(printf '%s' "$waits" | grep . | minmax)"
}

echo
echo "=== 1. cold start (force-stop, then launch) ==="
measure_starts "cold start" yes

echo
echo "=== 2. warm start (no force-stop, process still alive) ==="
# Send the app to the background first, otherwise the launch is a no-op on an
# activity that is already resumed and the number means nothing.
adb_ shell input keyevent KEYCODE_HOME
sleep 1
measure_starts "warm start" no

echo
echo "=== 3. jank while scrolling the chat ==="
# Bring the app forward and let it settle, so the reset below starts from a
# quiet screen instead of catching the launch animation.
adb_ shell am start -W -n "$ACTIVITY" >/dev/null 2>&1
sleep 3

SIZE="$(adb_ shell wm size | tr -d '\r' | awk -F'[: x]+' '/Physical size/{print $(NF-1), $NF}')"
WIDTH="${SIZE%% *}"
HEIGHT="${SIZE##* }"
MIDX=$((WIDTH / 2))
LOW=$((HEIGHT * 75 / 100))
HIGH=$((HEIGHT * 25 / 100))

adb_ shell dumpsys gfxinfo "$PKG" reset >/dev/null
# Twelve swipes, alternating up and down, 300 ms each — fast enough that a
# dropped frame shows, slow enough that the list actually renders rows rather
# than flinging past them.
for i in $(seq 1 12); do
  if [ $((i % 2)) -eq 0 ]; then
    adb_ shell input swipe "$MIDX" "$HIGH" "$MIDX" "$LOW" 300
  else
    adb_ shell input swipe "$MIDX" "$LOW" "$MIDX" "$HIGH" 300
  fi
done
sleep 1

adb_ shell dumpsys gfxinfo "$PKG" | tr -d '\r' | awk '
  /Total frames rendered/         { printf "  %s\n", $0 }
  /Janky frames/                  { printf "  %s\n", $0 }
  /percentile/                    { printf "  %s\n", $0 }
  /Number Missed Vsync/           { printf "  %s\n", $0 }
  /Number High input latency/     { printf "  %s\n", $0 }
  /Number Slow UI thread/         { printf "  %s\n", $0 }
  /Number Slow bitmap uploads/    { printf "  %s\n", $0 }
  /Number Slow issue draw commands/ { printf "  %s\n", $0 }
'

echo
echo "=== 4. memory ==="
adb_ shell dumpsys meminfo "$PKG" | tr -d '\r' | awk '
  /^ *TOTAL PSS:/ { printf "  %s\n", $0; found = 1 }
  /TOTAL +[0-9]/  { if (!found) printf "  %s\n", $0 }
'
echo
echo "done. Nothing on the device was installed, removed or changed."
