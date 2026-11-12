#!/usr/bin/env bash
# Makes `flutter test` ignore stray HTTP requests on its private test port.
#
# Why: every test file gets a flutter_tester process that connects back to a
# random localhost port; flutter_tools takes the FIRST request on that port
# and fails the whole file if it is not the tester's WebSocket upgrade:
#   Unable to connect to flutter_tester process: WebSocketException:
#   Invalid WebSocket upgrade request
# On this PC T3 Code's preview port scanner sends `GET /` to every listening
# localhost port every ~18 s (measured 2026-11-12, process `t3code`). Under
# load a test process needs a few seconds to connect, the scan wins the race,
# and tens of test files fail at random in a full run.
#
# The patch (flutter_tools, test/flutter_tester_device.dart, `remoteChannel`)
# answers any non-upgrade request with 404 and keeps waiting for the real one.
# It changes nothing else. `flutter upgrade` drops it: run this script again.
# Idempotent; `--revert` restores the file from git.
#
#   scripts/patch_flutter_test_connect.sh
#   scripts/patch_flutter_test_connect.sh --check   # exit 1 if not patched
#   scripts/patch_flutter_test_connect.sh --revert
set -euo pipefail

FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
FILE="$FLUTTER_ROOT/packages/flutter_tools/lib/src/test/flutter_tester_device.dart"
MARK="chuk_chat: skip stray requests"

[[ -f "$FILE" ]] || { echo "not found: $FILE" >&2; exit 2; }

case "${1:-}" in
  --check)
    grep -q "$MARK" "$FILE" && { echo "patched"; exit 0; }
    echo "NOT patched: run scripts/patch_flutter_test_connect.sh"; exit 1 ;;
  --revert)
    git -C "$FLUTTER_ROOT" checkout -- "$FILE"
    rm -f "$FLUTTER_ROOT/bin/cache/flutter_tools.stamp"
    echo "reverted; flutter_tools rebuilds on the next flutter command"; exit 0 ;;
esac

if grep -q "$MARK" "$FILE"; then
  echo "already patched"
  exit 0
fi

python3 - "$FILE" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1], sys.argv[2]
src = open(path).read()
old = """      final HttpRequest firstRequest = await _server!.first;
      final WebSocket webSocket = await WebSocketTransformer.upgrade(firstRequest);
      return _webSocketToStreamChannel(webSocket);"""
new = """      // %s (port scanners): answer any request that is not the
      // tester's WebSocket upgrade with 404 and keep waiting for the real one.
      await for (final HttpRequest request in _server!) {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        final WebSocket webSocket = await WebSocketTransformer.upgrade(request);
        return _webSocketToStreamChannel(webSocket);
      }
      throw const SocketException('test server closed before the tester connected');""" % mark
if old not in src:
    sys.exit("the code to patch was not found; Flutter changed it, patch by hand")
open(path, "w").write(src.replace(old, new, 1))
PY

# flutter_tools is a cached snapshot; drop its stamp so it is rebuilt.
rm -f "$FLUTTER_ROOT/bin/cache/flutter_tools.stamp"
echo "patched $FILE; flutter_tools rebuilds on the next flutter command"
