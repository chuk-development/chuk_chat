import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/cowork/cowork_demo_server.dart';
import 'package:chuk_chat/services/cowork/cowork_executor_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoworkExecutorBridge', () {
    test('start binds a loopback server and exposes its url', () async {
      final bridge = CoworkExecutorBridge(server: CoworkDemoServer());
      addTearDown(bridge.stop);

      final uri = await bridge.start(port: 0);

      expect(uri.host, '127.0.0.1');
      expect(uri.port, greaterThan(0));
      expect(bridge.isRunning, isTrue);
      expect(bridge.url, uri);
      expect(bridge.server.connectionCount, 0);
    });

    test('start is idempotent — returns the same url, no second server',
        () async {
      final bridge = CoworkExecutorBridge(server: CoworkDemoServer());
      addTearDown(bridge.stop);

      final first = await bridge.start(port: 0);
      final second = await bridge.start(port: 0);

      expect(second, first);
    });

    test('stop tears the server down and clears the url', () async {
      final bridge = CoworkExecutorBridge(server: CoworkDemoServer());
      await bridge.start(port: 0);

      await bridge.stop();

      expect(bridge.isRunning, isFalse);
      expect(bridge.url, isNull);
    });
  });
}
