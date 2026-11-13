#!/usr/bin/env bash
# Renders every phone screen of the Agents build headless, one PNG per
# screen, at the size of a Pixel 7 Pro (1440 x 3120 px, 3.5 px per dp).
#
# Output: _scratch/screens/<NN>_<name>.png and _scratch/screens/index.png, a
# sheet of all screens with their names, so a screen can be named in a
# message ("in 03_agent_settings the row ...").
#
# How: two scratch tests are built from the head (imports, fakes, helpers)
# of an existing widget test plus a body from tool/phone_screens/, run with
# --update-goldens and deleted again. No device, no backend, no login.
# A screen that cannot be reached is skipped and named in the output.
#
# Usage: scripts/phone_screens.sh
set -uo pipefail
cd "$(dirname "$0")/.."

OUT=_scratch/screens
mkdir -p "$OUT"
rm -f "$OUT"/*.png

# make <source test> <body part> <scratch test> <sed fix-ups...>
make() {
  local src=$1 part=$2 dst=$3
  shift 3
  local main
  main=$(grep -n '^void main() {' "$src" | head -1 | cut -d: -f1)
  { head -n $((main - 1)) "$src"; cat "$part"; } > "$dst"
  for fix in "$@"; do sed -i "$fix" "$dst"; done
}

SK=test/widgets/zz_phone_screens_sidekicks_test.dart
CH=test/platform_specific/zz_phone_screens_chats_test.dart
trap 'rm -f "$SK" "$CH"' EXIT

make test/widgets/messenger_shell_test.dart tool/phone_screens/sidekicks.dart.part "$SK" \
  's#show findId;#show findId, loadRealFonts;#' \
  "1i import 'package:chuk_chat/services/agents/thread_preview_store.dart';"
make test/platform_specific/root_wrapper_mobile_swipe_test.dart tool/phone_screens/chats.dart.part "$CH" \
  's#show findId;#show findId, loadRealFonts;#' \
  "1i import 'package:chuk_chat/constants.dart';" \
  "1i import 'package:chuk_chat/services/app_mode_service.dart';" \
  "1i import 'package:chuk_chat/services/app_theme_service.dart';" \
  "1i import 'package:chuk_chat/widgets/app_mode_switch.dart';"

for t in "$SK" "$CH"; do
  flutter test "$t" --update-goldens 2>&1 | grep -E '^SCREEN |^SKIPPED |error •|Error:|\[E\]' | sort -u
done

# The sheet: every screen with its name under it.
if command -v montage >/dev/null && ls "$OUT"/*.png >/dev/null 2>&1; then
  montage -background '#111111' -fill white -font DejaVu-Sans -pointsize 22 \
    -label '%t' "$OUT"/[0-9]*.png -resize 360x -tile 4x -geometry +16+16 \
    "$OUT/index.png"
fi
ls -1 "$OUT"
