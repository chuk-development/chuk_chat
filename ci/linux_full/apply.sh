#!/usr/bin/env bash
#
# Applied by the `build-linux-x64-full` / `build-linux-arm64-full` CI
# jobs before `flutter pub get`. Transforms the default slim codebase
# into a "full" Linux build by:
#
#   1. Inserting `webview_cef: ^0.2.2` into pubspec.yaml.
#   2. Overwriting `lib/widgets/linux_webview.dart` with the CEF-backed
#      version shipped in `ci/linux_full/lib/widgets/linux_webview.dart`.
#   3. Patching `lib/main.dart` to call `WebviewManager().initialize()`
#      once on startup (idempotent).
#
# Running this script outside of CI will leave local dev state dirty.
# Use `git stash` / a fresh checkout to unwind.

set -euo pipefail

# `cd` may print the destination when CDPATH is inherited from the
# caller's shell; redirect to /dev/null so `pwd` is the only output.
ROOT_DIR="$(cd "$(dirname "$0")/../.." >/dev/null && pwd)"
FULL_DIR="$ROOT_DIR/ci/linux_full"
PUBSPEC="$ROOT_DIR/pubspec.yaml"
SLIM_WIDGET="$ROOT_DIR/lib/widgets/linux_webview.dart"
FULL_WIDGET="$FULL_DIR/lib/widgets/linux_webview.dart"

if [[ ! -f "$FULL_WIDGET" ]]; then
  echo "::error::ci/linux_full/lib/widgets/linux_webview.dart missing" >&2
  exit 1
fi

# --- pubspec.yaml ---
if grep -q 'webview_cef:' "$PUBSPEC"; then
  echo "webview_cef already present in pubspec.yaml; skipping injection."
else
  # Insert immediately after the flutter_inappwebview line. `awk` keeps
  # YAML indentation intact (the line uses two spaces at the start).
  awk '
    /^  flutter_inappwebview: / {
      print
      print "  webview_cef: ^0.2.2"
      next
    }
    { print }
  ' "$PUBSPEC" > "$PUBSPEC.tmp"
  mv "$PUBSPEC.tmp" "$PUBSPEC"
  echo "Injected webview_cef into pubspec.yaml"
fi

# --- lib/widgets/linux_webview.dart ---
install -m 0644 "$FULL_WIDGET" "$SLIM_WIDGET"
echo "Swapped in CEF-backed lib/widgets/linux_webview.dart"

# --- lib/main.dart ---
MAIN="$ROOT_DIR/lib/main.dart"
if grep -q "WebviewManager().initialize" "$MAIN"; then
  echo "main.dart already initialises webview_cef; skipping."
else
  # Insert `await WebviewManager().initialize(...)` immediately after
  # `WidgetsFlutterBinding.ensureInitialized();` in main(). Imports are
  # prepended at the top of the file and keyed on the SYMBOL (not the
  # import line) so `import 'dart:io' show File;` is still recognised
  # as needing a `Platform` companion.
  python3 - "$MAIN" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
src = path.read_text()
if 'WebviewManager().initialize' in src:
    sys.exit(0)

needed_imports = []
if 'WebviewManager' not in src:
    needed_imports.append("import 'package:webview_cef/webview_cef.dart';")
# `Platform` from dart:io is needed for `Platform.isLinux`. Use a
# word-boundary regex so matches on `TargetPlatform`/`defaultTargetPlatform`
# don't hide the need for an import.
if not re.search(r'(?<![A-Za-z0-9_])Platform(?![A-Za-z0-9_])', src):
    needed_imports.append("import 'dart:io' show Platform;")
if not re.search(r'(?<![A-Za-z0-9_])kIsWeb(?![A-Za-z0-9_])', src):
    needed_imports.append(
        "import 'package:flutter/foundation.dart' show kIsWeb;"
    )
if needed_imports:
    src = "\n".join(needed_imports) + "\n" + src

src = re.sub(
    r'(WidgetsFlutterBinding\.ensureInitialized\(\);\s*\n)',
    r"\1  if (!kIsWeb && Platform.isLinux) {\n"
    r"    try { await WebviewManager().initialize(userAgent: 'chuk_chat'); } catch (_) {}\n"
    r"  }\n",
    src,
    count=1,
)
path.write_text(src)
PY
  echo "Patched main.dart to initialise webview_cef on Linux."
fi

echo "ci/linux_full/apply.sh complete."
