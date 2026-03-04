#!/bin/bash
# Helper script to run Flutter with environment variables from .env

set -e

show_usage() {
  cat <<EOF
Usage: ./run.sh [device|android-vm] [avd_name]

Examples:
  ./run.sh linux
  ./run.sh android
  ./run.sh android-x64
  ./run.sh android-vm
  ./run.sh android-vm Pixel_7_API_31

Tip:
  ./run.sh android resolves to connected android-x64 first.
  Set ANDROID_AVD_NAME to choose a default emulator:
  ANDROID_AVD_NAME=Pixel_7_API_31 ./run.sh android-vm
EOF
}

resolve_android_tool() {
  local tool_name="$1"
  local sdk_path=""
  local tool_path=""

  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return 0
  fi

  for sdk_path in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Android/Sdk"; do
    if [ -z "$sdk_path" ]; then
      continue
    fi

    case "$tool_name" in
      adb)
        tool_path="$sdk_path/platform-tools/adb"
        ;;
      *)
        return 1
        ;;
    esac

    if [ -x "$tool_path" ]; then
      printf '%s\n' "$tool_path"
      return 0
    fi
  done

  return 1
}

is_android_vm_booted() {
  local adb_bin="$1"
  local emulator_id="$2"
  local sys_boot=""
  local dev_boot=""
  local boot_anim=""

  sys_boot=$("$adb_bin" -s "$emulator_id" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  dev_boot=$("$adb_bin" -s "$emulator_id" shell getprop dev.bootcomplete 2>/dev/null | tr -d '\r')
  boot_anim=$("$adb_bin" -s "$emulator_id" shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')

  [ "$sys_boot" = "1" ] && [ "$dev_boot" = "1" ] && [ "$boot_anim" = "stopped" ]
}

resolve_device_alias() {
  local requested="$1"
  local devices_json=""
  local line=""
  local trimmed_line=""
  local current_id=""
  local current_platform=""
  local current_supported=""
  local first_android_device=""
  local android_x64_device=""
  local android_arm64_device=""

  case "$requested" in
    android|android-x64|android-arm64)
      ;;
    *)
      printf '%s\n' "$requested"
      return 0
      ;;
  esac

  if ! devices_json="$(flutter devices --machine 2>/dev/null)"; then
    printf '%s\n' "$requested"
    return 0
  fi

  while IFS= read -r line; do
    trimmed_line="${line#"${line%%[![:space:]]*}"}"

    case "$trimmed_line" in
      '"id": "'*'",')
        current_id="${trimmed_line#\"id\": \"}"
        current_id="${current_id%%\",*}"
        ;;
      '"isSupported": true,')
        current_supported="true"
        ;;
      '"isSupported": false,')
        current_supported="false"
        ;;
      '"targetPlatform": "'*'",')
        current_platform="${trimmed_line#\"targetPlatform\": \"}"
        current_platform="${current_platform%%\",*}"

        if [ "$current_supported" = "true" ] && [[ "$current_platform" == android-* ]] && [ -n "$current_id" ]; then
          if [ -z "$first_android_device" ]; then
            first_android_device="$current_id"
          fi

          if [ "$current_platform" = "android-x64" ] && [ -z "$android_x64_device" ]; then
            android_x64_device="$current_id"
          fi

          if [ "$current_platform" = "android-arm64" ] && [ -z "$android_arm64_device" ]; then
            android_arm64_device="$current_id"
          fi
        fi
        ;;
    esac
  done <<<"$devices_json"

  case "$requested" in
    android)
      if [ -n "$android_x64_device" ]; then
        printf '%s\n' "$android_x64_device"
      elif [ -n "$first_android_device" ]; then
        printf '%s\n' "$first_android_device"
      else
        printf '%s\n' "$requested"
      fi
      ;;
    android-x64)
      if [ -n "$android_x64_device" ]; then
        printf '%s\n' "$android_x64_device"
      elif [ -n "$first_android_device" ]; then
        printf '%s\n' "$first_android_device"
      else
        printf '%s\n' "$requested"
      fi
      ;;
    android-arm64)
      if [ -n "$android_arm64_device" ]; then
        printf '%s\n' "$android_arm64_device"
      elif [ -n "$first_android_device" ]; then
        printf '%s\n' "$first_android_device"
      else
        printf '%s\n' "$requested"
      fi
      ;;
  esac
}

is_connected_adb_device() {
  local adb_bin="$1"
  local device_id="$2"

  "$adb_bin" devices | awk -v id="$device_id" '$1 == id && $2 == "device" { found = 1 } END { exit found ? 0 : 1 }'
}

configure_android_local_api_access() {
  local device_id="$1"
  local adb_bin=""

  # Respect explicit LOCAL_API_URL from .env or shell.
  if [ -n "$LOCAL_API_URL" ]; then
    return 0
  fi

  if ! adb_bin="$(resolve_android_tool adb)"; then
    return 0
  fi

  if ! is_connected_adb_device "$adb_bin" "$device_id"; then
    return 0
  fi

  # Map device localhost:8000 to host localhost:8000 so debug builds can
  # keep using ws://localhost:8000 and http://localhost:8000.
  if "$adb_bin" -s "$device_id" reverse tcp:8000 tcp:8000 >/dev/null 2>&1; then
    echo "Configured Android local API tunnel on $device_id (localhost:8000 -> host:8000)" >&2
    return 0
  fi

  # Fallbacks when adb reverse is unavailable.
  case "$device_id" in
    emulator-*)
      LOCAL_API_URL="http://10.0.2.2:8000"
      ;;
    127.0.0.1:*)
      LOCAL_API_URL="http://10.0.3.2:8000"
      ;;
  esac

  if [ -n "$LOCAL_API_URL" ]; then
    echo "Using Android fallback LOCAL_API_URL=$LOCAL_API_URL for $device_id" >&2
  else
    echo "Warning: could not configure Android local API access for $device_id" >&2
    echo "Tip: set LOCAL_API_URL=http://<host-ip>:8000" >&2
  fi
}

start_android_vm() {
  local avd_name="${1:-${ANDROID_AVD_NAME:-}}"
  local adb_bin=""
  local emulators_output=""
  local emulator_line=""
  local emulator_candidate=""
  local first_emulator=""
  local preferred_emulator=""
  local pixel7_emulator=""
  local emulator_id=""
  local elapsed=0
  local max_wait_seconds=240

  if ! adb_bin="$(resolve_android_tool adb)"; then
    echo "Error: adb command not found. Install Android platform-tools." >&2
    exit 1
  fi

  "$adb_bin" start-server >/dev/null

  emulator_id=$("$adb_bin" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
  if [ -n "$emulator_id" ]; then
    echo "Android VM already running: $emulator_id" >&2
    printf '%s\n' "$emulator_id"
    return 0
  fi

  if [ -z "$avd_name" ]; then
    if ! emulators_output="$(flutter emulators)"; then
      echo "Error: failed to list Android Virtual Devices via Flutter CLI." >&2
      exit 1
    fi

    while IFS= read -r emulator_line; do
      case "$emulator_line" in
        [A-Za-z0-9._-]*)
          emulator_candidate="${emulator_line%% *}"

          if [ "$emulator_candidate" = "Id" ] || [ "$emulator_candidate" = "To" ]; then
            continue
          fi

          if [ -z "$first_emulator" ]; then
            first_emulator="$emulator_candidate"
          fi

          if [ "$emulator_candidate" = "Pixel_7_API_31" ]; then
            preferred_emulator="$emulator_candidate"
          fi

          if [ -z "$pixel7_emulator" ] && [[ "$emulator_candidate" == *Pixel_7* ]]; then
            pixel7_emulator="$emulator_candidate"
          fi
          ;;
      esac
    done <<<"$emulators_output"

    if [ -n "$preferred_emulator" ]; then
      avd_name="$preferred_emulator"
    elif [ -n "$pixel7_emulator" ]; then
      avd_name="$pixel7_emulator"
    else
      avd_name="$first_emulator"
    fi
  fi

  if [ -z "$avd_name" ]; then
    echo "Error: no Android Virtual Device found." >&2
    echo "Create one in Android Studio Device Manager or set ANDROID_AVD_NAME." >&2
    exit 1
  fi

  echo "Starting Android VM (cold boot): $avd_name" >&2
  if ! flutter emulators --launch "$avd_name" --cold >/dev/null; then
    echo "Error: failed to launch Android VM '$avd_name'." >&2
    echo "Try: flutter emulators (list IDs), then rerun with ./run.sh android-vm <id>" >&2
    exit 1
  fi

  echo "Waiting for Android VM to boot..." >&2
  while [ "$elapsed" -lt "$max_wait_seconds" ]; do
    emulator_id=$("$adb_bin" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')

    if [ -n "$emulator_id" ] && is_android_vm_booted "$adb_bin" "$emulator_id"; then
      sleep 3
      elapsed=$((elapsed + 3))
      if "$adb_bin" -s "$emulator_id" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
        echo "Android VM is ready: $emulator_id" >&2
        printf '%s\n' "$emulator_id"
        return 0
      fi

      continue
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  echo "Error: timed out waiting for Android VM to boot." >&2
  echo "Check Android Studio Device Manager and run: flutter emulators" >&2
  exit 1
}

# Default to linux if no device specified
TARGET="${1:-linux}"

if [ "$TARGET" = "-h" ] || [ "$TARGET" = "--help" ]; then
  show_usage
  exit 0
fi

# Load .env file if it exists
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Check if credentials are set
if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
  echo "Error: SUPABASE_URL and SUPABASE_ANON_KEY must be set."
  echo "Copy .env.example to .env and fill in your values."
  exit 1
fi

case "$TARGET" in
  android-vm)
    DEVICE="$(start_android_vm "${2:-}")"
    ;;
  *)
    DEVICE="$(resolve_device_alias "$TARGET")"
    if [ "$DEVICE" != "$TARGET" ]; then
      echo "Resolved device alias '$TARGET' to '$DEVICE'" >&2
    fi
    ;;
esac

configure_android_local_api_access "$DEVICE"

# Build dart-define arguments
DART_DEFINES="--dart-define=SUPABASE_URL=$SUPABASE_URL --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"

# Override the local API server URL (debug builds use http://localhost:8000 by default).
# Set LOCAL_API_URL in .env or export it to change:
#   LOCAL_API_URL=http://192.168.1.10:8000  ./run.sh linux
if [ -n "$LOCAL_API_URL" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=LOCAL_API_URL=$LOCAL_API_URL"
fi

# Add any additional dart-defines for features
if [ -n "$FEATURE_PROJECTS" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=FEATURE_PROJECTS=$FEATURE_PROJECTS"
fi
if [ -n "$FEATURE_IMAGE_GEN" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=FEATURE_IMAGE_GEN=$FEATURE_IMAGE_GEN"
fi
if [ -n "$FEATURE_VOICE_MODE" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=FEATURE_VOICE_MODE=$FEATURE_VOICE_MODE"
fi

# Run Flutter
echo "Running flutter in debug mode with device: $DEVICE"
flutter run -d "$DEVICE" $DART_DEFINES
