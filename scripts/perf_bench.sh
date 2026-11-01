#!/usr/bin/env bash
# Benchmark: builds a profile APK of test_driver/perf_bench_main.dart as
# package dev.chuk.chat.perf, NEXT TO the real app, and runs it with synthetic
# data. It never touches dev.chuk.chat: no install, no uninstall, no clear.
#
# The app has no real credentials, and test_driver/perf_bench/bench_guard.dart
# blocks all dart:io network traffic, so it reaches no backend. The run prints
# the app's traffic as proof. All synthetic chats live in that package and go
# with it: the script uninstalls it at the end unless --keep is given.
#
# Usage: scripts/perf_bench.sh [--serial S] [--label before] [--no-build]
#                              [--cold N] [--census|--census-widgets] [--keep]
#                              [--crawl|--crawl-agents] [--no-semantics]
# Runs on the AVD only (scripts/emulator.sh, headless). The device: --serial,
# else $ANDROID_SERIAL, else the running emulator. A physical phone is refused.
# Output: table on stdout, raw rows in _scratch/perf/<label>.jsonl.
# Docs: docs/PERFORMANCE.md
set -euo pipefail
cd "$(dirname "$0")/.."

SERIAL=${ANDROID_SERIAL:-} MODE=bench LABEL=run SEMANTICS=true BUILD=1 COLD=5 CENSUS=false WIDGETS=false KEEP=
while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --no-build) BUILD=; shift ;;
    --cold) COLD=$2; shift 2 ;;
    --census) CENSUS=true; shift ;;
    --census-widgets) CENSUS=true; WIDGETS=true; shift ;;
    --keep) KEEP=1; shift ;;
    --no-semantics) SEMANTICS=false; shift ;;
    --crawl) MODE=crawl; COLD=0; shift ;;
    --crawl-agents) MODE=crawl-agents; COLD=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$SERIAL" ] || SERIAL=$(adb devices | awk '$1 ~ /^emulator-/ && $2=="device"{print $1; exit}')
case "$SERIAL" in
  emulator-*) ;;
  "") echo "no emulator running: scripts/emulator.sh start" >&2; exit 2 ;;
  *) echo "refused: $SERIAL is not an emulator" >&2; exit 2 ;;
esac

PKG=dev.chuk.chat.perf
APK=build/app/outputs/flutter-apk/app-profile.apk
OUT=_scratch/perf/$LABEL.jsonl
mkdir -p _scratch/perf
a() { adb -s "$SERIAL" "$@"; }

if [ -n "$BUILD" ]; then
  # No real credentials on purpose: not --dart-define-from-file, and the
  # Supabase host is 127.0.0.1:9, where nothing answers.
  ORG_GRADLE_PROJECT_benchIdSuffix=.perf flutter build apk --profile \
    -t test_driver/perf_bench_main.dart --target-platform android-x64 \
    --dart-define=FEATURE_AGENTS=true \
    --dart-define=SUPABASE_URL=http://127.0.0.1:9 \
    --dart-define=SUPABASE_ANON_KEY=bench \
    --dart-define=BENCH_MODE=$MODE \
    --dart-define=BENCH_SEMANTICS=$SEMANTICS \
    --dart-define=BENCH_CENSUS=$CENSUS \
    --dart-define=BENCH_CENSUS_WIDGETS=$WIDGETS
fi

# adb install only: `flutter run/drive` uninstalls the old package when an
# install fails, and that must never get near the owner's app.
# The soft keyboard must be the real one, or the keyboard phases measure nothing.
scripts/emulator.sh keyboard 1 >/dev/null 2>&1 || true
a install -r -t "$APK" >/dev/null
for perm in android.permission.RECORD_AUDIO android.permission.POST_NOTIFICATIONS; do
  a shell pm grant "$PKG" "$perm" || true
done
a shell dumpsys deviceidle whitelist +"$PKG" >/dev/null || true
a shell pm clear "$PKG" >/dev/null
for perm in android.permission.RECORD_AUDIO android.permission.POST_NOTIFICATIONS; do
  a shell pm grant "$PKG" "$perm" || true
done
# The screen must stay on for the run.
a shell svc power stayon usb
a shell input keyevent KEYCODE_WAKEUP

: >"$OUT"
a logcat -c
a logcat -v raw -s flutter:I | grep --line-buffered '^PERFBENCH ' | sed -u 's/^PERFBENCH //' >>"$OUT" &
LOG=$!
WATCH=
cleanup() {
  kill $LOG $WATCH 2>/dev/null || true
  a shell svc power stayon false || true
  # Only ever the benchmark package. Its data holds all synthetic chats.
  if [ -z "$KEEP" ]; then
    a uninstall "$PKG" >/dev/null 2>&1 || true
    a shell dumpsys deviceidle whitelist -"$PKG" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
if [ "$CENSUS" = true ]; then
  python3 scripts/perf_census.py "$SERIAL" "$LABEL" &
  sleep 1
fi
# Dart CPU samples for the census: the profiler is off without this.
a shell am start -n "$PKG/dev.chuk.chat.MainActivity" \
  --ez enable-dart-profiling true >/dev/null

# A button may open a system screen (file picker, permission, settings).
# Back out of it and bring the app to the front again.
if [ "$MODE" != bench ]; then
  (
    # The app needs a moment to reach the front; BACK now would close it.
    sleep 25
    while sleep 2; do
      TOP=$(a shell dumpsys window | grep -m1 mFocusedApp |
        sed -E 's/.* ([A-Za-z0-9_.]+)\/.*/\1/')
      case "$TOP" in
        "$PKG" | "") ;;
        # A system screen a button opened: file picker, share sheet, the
        # clipboard popup. BACK closes it and hands the app its cancel.
        # Not force-stop: that takes the app's own task down with it.
        *)
          echo "watchdog: back out of $TOP"
          a shell input keyevent KEYCODE_BACK
          sleep 2
          case "$(a shell dumpsys window | grep -m1 mFocusedApp)" in
            *"$PKG"*) ;;
            *) a shell am start -n "$PKG/dev.chuk.chat.MainActivity" >/dev/null 2>&1 ;;
          esac
          ;;
      esac
    done
  ) &
  WATCH=$!
fi

# The AVD's RSS over the run. Its host process can grow far past hw.ramSize, so
# past 8 GB the run stops: the machine has other work on it.
qemu_rss_mb() {
  ps -eo rss,args | awk '/[q]emu-system-x86_64/{printf "%d\n", $1/1024; exit}'
}
RSS_LOG=_scratch/perf/$LABEL.rss
: >"$RSS_LOG"
RSS_LIMIT_MB=8192
OVER=0

# 40 minutes at most for the whole scenario.
for _ in $(seq 1 2400); do
  MB=$(qemu_rss_mb)
  echo "$(date +%T) ${MB:-0}" >>"$RSS_LOG"
  # An install peaks for a few seconds and falls back; only a lasting value
  # counts.
  if [ "${MB:-0}" -gt "$RSS_LIMIT_MB" ]; then
    OVER=$((OVER + 1))
  else
    OVER=0
  fi
  if [ "$OVER" -ge 30 ]; then
    echo "stopped: qemu RSS ${MB} MB, over $RSS_LIMIT_MB MB for 30 s; restart the AVD" >&2
    break
  fi
  grep -q '"done":true' "$OUT" 2>/dev/null && break
  grep -q '"found":false' "$OUT" 2>/dev/null && { echo "shell never showed"; break; }
  sleep 1
done

# Cold starts, on the seeded data.
for i in $(seq 1 "$COLD"); do
  a shell am force-stop "$PKG"
  sleep 2
  T=$(a shell 'date +%s%3N; am start -W -n '"$PKG"'/dev.chuk.chat.MainActivity' | tr -d '\r')
  START=$(echo "$T" | sed -n 1p)
  TOTAL=$(echo "$T" | sed -n 's/^TotalTime: //p')
  echo "{\"coldrun\":$i,\"start_epoch\":$START,\"am_total_ms\":${TOTAL:-0}}" >>"$OUT"
  sleep 8
done

UID_=$(a shell dumpsys package "$PKG" | sed -n 's/.*appId=\([0-9]*\).*/\1/p' | head -1)
echo "traffic of uid $UID_ since boot (rb/tb bytes, must not grow in a run):"
a shell dumpsys netstats detail | grep -A3 "uid=$UID_ " | grep -E 'rb=' || echo "  none"
a shell am force-stop "$PKG"
python3 scripts/perf_bench_table.py "$OUT"
