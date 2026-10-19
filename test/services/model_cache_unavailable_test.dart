// The chat screens look up the selected model's name unawaited. When the
// local cache cannot be opened (here: no application support directory), the
// lookup must answer "no name" instead of throwing an uncaught async error.
// On a slow CI runner that error failed
// `agents_thread_table_test.dart` ("a file in the Agents thread follows the
// answer text"), whose run mocks path_provider to return nothing.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/model_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a cache that cannot be opened gives no name, not an error', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ModelCacheService.debugClearMemo();
    const MethodChannel channel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await ModelCacheService.displayNameFor('a/one'), isNull);
  });
}
