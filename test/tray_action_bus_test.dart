import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tray_action_bus.dart';

void main() {
  group('TrayActionBus', () {
    test('is a singleton', () {
      expect(TrayActionBus.instance, same(TrayActionBus.instance));
    });

    test('requestNewChat bumps the notifier and fires listeners', () {
      final bus = TrayActionBus.instance;
      final start = bus.newChatRequested.value;

      var fired = 0;
      void listener() => fired++;
      bus.newChatRequested.addListener(listener);
      addTearDown(() => bus.newChatRequested.removeListener(listener));

      bus.requestNewChat();
      expect(bus.newChatRequested.value, start + 1);
      expect(fired, 1);

      bus.requestNewChat();
      expect(bus.newChatRequested.value, start + 2);
      expect(fired, 2);
    });
  });
}
