import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/auth_trace.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('keeps one line per event, newest last', () async {
    AuthTrace.note('signed-out', detail: <String, Object?>{'reason': 'expired'});
    AuthTrace.note('recovery-done', detail: <String, Object?>{'outcome': 'ok'});
    // The writes are fire-and-forget; let them land.
    await AuthTrace.settled();

    final List<String> lines = await AuthTrace.read();

    expect(lines, hasLength(2));
    expect(lines.first, contains('signed-out'));
    expect(lines.first, contains('"reason":"expired"'));
    expect(lines.last, contains('recovery-done'));
  });

  test('drops the oldest past the cap', () async {
    for (int i = 0; i < AuthTrace.keep + 5; i++) {
      AuthTrace.note('event-$i');
    }
    await AuthTrace.settled();

    final List<String> lines = await AuthTrace.read();

    expect(lines, hasLength(AuthTrace.keep));
    expect(lines.first, contains('event-5'));
    expect(lines.last, contains('event-${AuthTrace.keep + 4}'));
  });

  test('clear empties it', () async {
    AuthTrace.note('signed-out');
    await AuthTrace.clear();

    expect(await AuthTrace.read(), isEmpty);
  });
}
