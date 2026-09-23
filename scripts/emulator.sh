#!/usr/bin/env bash
# Local Android emulator for Agents: one x86_64 AVD, KVM, NVIDIA GPU.
#
# The phone (Pixel 7 Pro, arm64) stays the release target. This AVD is the
# target an agent can start without hardware. It is x86_64 because the host is
# x86_64: arm64 images run without KVM and are unusably slow.
#
# Usage:
#   scripts/emulator.sh start    # create the AVD if needed, boot it, wait
#   scripts/emulator.sh wait     # block until sys.boot_completed=1
#   scripts/emulator.sh status   # AVD, serial, boot state, GPU mode
#   scripts/emulator.sh shot [out.png]
#   scripts/emulator.sh keyboard 1  # bring the on-screen keyboard back
#   scripts/emulator.sh stop     # graceful shutdown
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
EMULATOR="$SDK/emulator/emulator"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
ADB="${ADB:-$(command -v adb || echo "$SDK/platform-tools/adb")}"

AVD="${AGENTS_AVD:-cowork_x64}"
IMAGE="${AGENTS_AVD_IMAGE:-system-images;android-36;google_apis;x86_64}"
DEVICE="${AGENTS_AVD_DEVICE:-pixel_7_pro}"
RAM_MB="${AGENTS_AVD_RAM:-4096}"
DATA_GB="${AGENTS_AVD_DATA:-8}"
GPU_MODE="${AGENTS_AVD_GPU:-host}"
LOG="${AGENTS_AVD_LOG:-/tmp/agents-emulator.log}"
GBOARD_PKG="com.google.android.inputmethod.latin"
GBOARD="$GBOARD_PKG/com.android.inputmethod.latin.LatinIME"

avd_dir() { echo "${ANDROID_AVD_HOME:-$HOME/.android/avd}/$AVD.avd"; }

serial() {
  # The emulator console port is the serial. Take the first booted emulator.
  "$ADB" devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1; exit}'
}

create_avd() {
  [ -d "$(avd_dir)" ] && return 0
  [ -x "$AVDMANAGER" ] || { echo "avdmanager not found at $AVDMANAGER" >&2; exit 1; }
  echo "==> creating AVD $AVD ($IMAGE, $DEVICE)"
  echo no | "$AVDMANAGER" create avd -n "$AVD" -k "$IMAGE" -d "$DEVICE" >/dev/null
  local cfg="$(avd_dir)/config.ini"
  # avdmanager writes the device profile only; the sizes and the GPU are ours.
  python3 - "$cfg" "$RAM_MB" "$DATA_GB" "$GPU_MODE" <<'PY'
import sys
cfg, ram, data, gpu = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
want = {
    "hw.ramSize": ram,
    "vm.heapSize": "512",
    "disk.dataPartition.size": f"{data}G",
    "hw.gpu.enabled": "yes",
    "hw.gpu.mode": gpu,
    "hw.keyboard": "yes",
    "hw.cpu.ncore": "4",
    "showDeviceFrame": "no",
}
lines = open(cfg).read().splitlines()
out, seen = [], set()
for line in lines:
    key = line.split("=", 1)[0].strip()
    if key in want:
        out.append(f"{key}={want[key]}")
        seen.add(key)
    else:
        out.append(line)
out += [f"{k}={v}" for k, v in want.items() if k not in seen]
open(cfg, "w").write("\n".join(out) + "\n")
PY
}

start() {
  [ -x "$EMULATOR" ] || { echo "emulator not found at $EMULATOR" >&2; exit 1; }
  [ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "no access to /dev/kvm (group kvm?)" >&2; exit 1; }
  if [ -n "$(serial)" ]; then echo "already running: $(serial)"; return 0; fi
  create_avd
  echo "==> booting $AVD (gpu=$GPU_MODE, log: $LOG)"
  # The guest holds its whole RAM plus the GPU buffers, so it sits near 5 GB RSS
  # and the memguard default of 6 GB would kill it mid-session. Bluetooth and
  # WiFi emulation (netsimd) burn CPU for nothing here, and audio has no use.
  local guard=()
  command -v memguard-allow >/dev/null && guard=(memguard-allow 8G)
  setsid "${guard[@]}" "$EMULATOR" -avd "$AVD" -gpu "$GPU_MODE" -accel on \
    -no-boot-anim -no-metrics -no-audio -feature -Bluetooth \
    ${AGENTS_AVD_EXTRA:-} >"$LOG" 2>&1 < /dev/null &
  wait_boot
}

tune_input() {
  # This AVD is driven from a real keyboard and a mouse, so the on-screen
  # keyboard is only in the way: Gboard keeps a suggestion strip on screen even
  # with `show_ime_with_hard_keyboard=0`, and it covers the app. Disabling the
  # IME removes the strip; physical key events still reach the app, because they
  # arrive as ordinary key events and never went through the IME.
  local s; s="$(serial)"
  [ -n "$s" ] || return 0
  "$ADB" -s "$s" shell settings put secure show_ime_with_hard_keyboard 0 >/dev/null 2>&1 || true
  if [ "${AGENTS_AVD_SOFT_KEYBOARD:-0}" = "1" ]; then
    "$ADB" -s "$s" shell pm enable "$GBOARD_PKG" >/dev/null 2>&1 || true
    "$ADB" -s "$s" shell ime enable "$GBOARD" >/dev/null 2>&1 || true
    "$ADB" -s "$s" shell ime set "$GBOARD" >/dev/null 2>&1 || true
    return 0
  fi
  # `ime disable` does not hold: with no other typing IME installed, Android
  # picks Gboard again on the next focus and the strip is back. Disabling the
  # package for this user does hold, and the voice IME stays as the system's
  # nominal default without drawing anything.
  "$ADB" -s "$s" shell pm disable-user --user 0 "$GBOARD_PKG" >/dev/null 2>&1 || true
}

wait_boot() {
  local deadline=$(( $(date +%s) + ${1:-300} ))
  "$ADB" start-server >/dev/null 2>&1 || true
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local s; s="$(serial)"
    if [ -n "$s" ] && [ "$("$ADB" -s "$s" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      tune_input
      echo "booted: $s"
      return 0
    fi
    sleep 3
  done
  echo "emulator did not boot in time — see $LOG" >&2
  return 1
}

status() {
  local s; s="$(serial)"
  echo "avd:    $AVD ($( [ -d "$(avd_dir)" ] && echo present || echo missing ))"
  echo "image:  $IMAGE"
  echo "serial: ${s:-none}"
  if [ -n "$s" ]; then
    echo "boot:   $("$ADB" -s "$s" shell getprop sys.boot_completed | tr -d '\r')"
    echo "abi:    $("$ADB" -s "$s" shell getprop ro.product.cpu.abi | tr -d '\r')"
    echo "sdk:    $("$ADB" -s "$s" shell getprop ro.build.version.sdk | tr -d '\r')"
    echo "gl:     $("$ADB" -s "$s" shell getprop ro.hardware.egl | tr -d '\r')"
  fi
}

shot() {
  local s; s="$(serial)"
  [ -n "$s" ] || { echo "no emulator running" >&2; exit 1; }
  local out="${1:-/tmp/agents-emulator.png}"
  "$ADB" -s "$s" exec-out screencap -p > "$out"
  echo "$out"
}

stop() {
  local s; s="$(serial)"
  [ -n "$s" ] || { echo "not running"; return 0; }
  "$ADB" -s "$s" emu kill >/dev/null 2>&1 || true
  echo "stopped $s"
}

case "${1:-start}" in
  start) start ;;
  keyboard) shift; AGENTS_AVD_SOFT_KEYBOARD="${1:-0}" tune_input ;;
  wait) shift; wait_boot "${1:-300}" ;;
  status) status ;;
  shot) shift; shot "${1:-}" ;;
  stop) stop ;;
  *) echo "usage: $0 {start|wait|status|shot [out.png]|keyboard [0|1]|stop}" >&2; exit 2 ;;
esac
