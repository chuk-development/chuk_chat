import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/notifications/notification_avatar.dart';
import 'package:chuk_chat/services/share/share_target_icon.dart';

void main() {
  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('avatar_test');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('the badge is 192 px, round: clear corners, a filled middle', (
    WidgetTester tester,
  ) async {
    final Uint8List? png = await tester.runAsync<Uint8List?>(
      () => paintShareTargetIcon(
        agentId: 'agent-7',
        name: 'Research',
        store: AgentProfileStore(),
        size: AgentNotificationAvatar.size,
        badge: true,
      ),
    );
    expect(png, isNotNull);
    expect(png!.length, lessThanOrEqualTo(AgentNotificationAvatar.maxPngBytes));
    final img.Image? image = img.decodePng(png);
    expect(image, isNotNull);
    expect(image!.width, 192);
    expect(image.height, 192);
    for (final (int x, int y) in <(int, int)>[
      (0, 0),
      (191, 0),
      (0, 191),
      (191, 191),
    ]) {
      expect(image.getPixel(x, y).a, 0, reason: 'corner ($x,$y) is clear');
    }
    expect(image.getPixel(96, 96).a, 255, reason: 'the middle is filled');
    // Just inside the circle at the left edge: the tinted background.
    expect(image.getPixel(4, 96).a, greaterThan(200));
  });

  testWidgets('the share icon keeps its full square', (
    WidgetTester tester,
  ) async {
    final Uint8List? png = await tester.runAsync<Uint8List?>(
      () => paintShareTargetIcon(
        agentId: 'agent-7',
        name: 'Research',
        store: AgentProfileStore(),
      ),
    );
    final img.Image image = img.decodePng(png!)!;
    expect(image.width, 432);
    expect(image.getPixel(0, 0).a, 255);
  });

  group('cache', () {
    late int paints;
    late AgentProfileStore store;
    late AgentNotificationAvatar avatars;

    setUp(() {
      paints = 0;
      store = AgentProfileStore();
      avatars = AgentNotificationAvatar(
        supportDir: () async => tmp,
        profiles: store,
        paintPng: (String id, String name, double size) async {
          paints++;
          return Uint8List.fromList(<int>[137, 80, 78, 71, paints]);
        },
      );
    });

    test('paints once, then reuses the file', () async {
      final String? a = await avatars.ensure('agent-7', name: 'Research');
      final String? b = await avatars.ensure('agent-7', name: 'Research');
      expect(a, isNotNull);
      expect(a, b);
      expect(paints, 1);
      expect(await avatars.cachedPath('agent-7'), a);
      expect(await avatars.cachedPath('unknown'), isNull);
    });

    test('a rename or a new photo paints again', () async {
      await avatars.ensure('agent-7', name: 'Research');
      await avatars.ensure('agent-7', name: 'Recherche');
      expect(paints, 2);
      await store.update('agent-7', photoPath: '/x/face.png');
      await avatars.ensure('agent-7', name: 'Recherche');
      expect(paints, 3);
    });

    test('a PNG over 128 KB is painted smaller', () async {
      final List<double> sizes = <double>[];
      final AgentNotificationAvatar big = AgentNotificationAvatar(
        supportDir: () async => tmp,
        profiles: store,
        paintPng: (String id, String name, double size) async {
          sizes.add(size);
          return Uint8List(size > 150 ? 200 * 1024 : 1000);
        },
      );
      final Uint8List? bytes = await big.pngBytes('a', name: 'A');
      expect(bytes?.length, 1000);
      expect(sizes, <double>[192, 160, 128]);
    });

    test('forget removes the file', () async {
      await avatars.ensure('agent-7', name: 'Research');
      await avatars.forget('agent-7');
      expect(await avatars.cachedPath('agent-7'), isNull);
    });

    test('an id with odd characters is a safe file name', () {
      expect(AgentNotificationAvatar.safeId('host:dev/1'), 'host_dev_1');
    });
  });
}
