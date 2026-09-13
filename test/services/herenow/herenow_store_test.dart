import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/herenow/herenow_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('defaults to disabled + ask when nothing is stored', () async {
    final settings = await HereNowStore().load();
    expect(settings.enabled, isFalse);
    expect(settings.approval, HereNowApproval.ask);
  });

  test('persists and reloads enabled + approval', () async {
    final store = HereNowStore();
    await store.save(
      const HereNowSettings(enabled: true, approval: HereNowApproval.auto),
    );

    final reloaded = await HereNowStore().load();
    expect(reloaded.enabled, isTrue);
    expect(reloaded.approval, HereNowApproval.auto);
  });

  test('forwardPayload is null when disabled', () async {
    final store = HereNowStore();
    await store.save(const HereNowSettings(enabled: false));
    expect(await store.forwardPayload(), isNull);
  });

  test('forwardPayload carries {enabled, approval} when enabled', () async {
    final store = HereNowStore();
    await store.save(
      const HereNowSettings(enabled: true, approval: HereNowApproval.ask),
    );
    expect(
      await store.forwardPayload(),
      <String, dynamic>{'enabled': true, 'approval': 'ask'},
    );
  });

  test('a corrupt or unknown approval reads back as the safe ask default',
      () async {
    // Directly seed a bad value; the store must not read it as `auto`.
    SharedPreferences.setMockInitialValues(<String, Object>{
      HereNowStore.prefsKey: '{"enabled":true,"approval":"nonsense"}',
    });
    final settings = await HereNowStore().load();
    expect(settings.enabled, isTrue);
    expect(settings.approval, HereNowApproval.ask);
  });
}
