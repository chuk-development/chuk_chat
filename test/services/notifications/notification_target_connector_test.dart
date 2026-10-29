import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/notifications/notification_router.dart';

void main() {
  test('a "sign-in expired" notice targets its connector, not a thread', () {
    final target = NotificationTarget.fromData(<Object?, Object?>{
      'kind': 'mcp_signin_expired',
      'session_key': 'mcp-connector:fastmail',
      'run_id': 'mcp-auth:abc',
    });
    expect(target, isNotNull);
    expect(target!.connectorId, 'fastmail');
  });

  test('an ordinary run notice has no connector', () {
    final target = NotificationTarget.fromData(<Object?, Object?>{
      'kind': 'completed',
      'session_key': 'mcp-connector:fastmail',
    });
    expect(target!.connectorId, isNull);
    expect(target.sessionKey, 'mcp-connector:fastmail');
  });
}
