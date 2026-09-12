import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/mcp/mcp_service.dart';

void main() {
  setUp(() => McpService.unreachable.value = <String>{});

  group('unreachable', () {
    test('a server that is not connected is never reported as reachable', () async {
      // Nothing is connected in a fresh test binding, so the check has no
      // connection to ask and must not claim the server is alive.
      expect(await McpService.verifyReachable('nothing-here'), isFalse);
      // And it records nothing: a server that does not exist is not a server
      // that went away.
      expect(McpService.unreachable.value, isEmpty);
    });

    test('checking every connection with none stored is a no-op', () async {
      await McpService.verifyAllReachable();
      expect(McpService.unreachable.value, isEmpty);
    });
  });
}
