import 'dart:convert';

import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const String key = 'cowork_thread_read_marks_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentReadMarks.persistDelay = const Duration(milliseconds: 50);
  });
  tearDown(() => AgentReadMarks.persistDelay = Duration.zero);

  test('a burst of marks is one write, after the burst', () async {
    final marks = AgentReadMarks();
    final prefs = await SharedPreferences.getInstance();
    final first = marks.markRead('a', when: DateTime.utc(2026, 1, 1));
    final second = marks.markRead('b', when: DateTime.utc(2026, 1, 2));

    // In memory at once: the unread dots read this, not the disk.
    expect(marks.lastRead('a'), DateTime.utc(2026, 1, 1));
    expect(marks.lastRead('b'), DateTime.utc(2026, 1, 2));
    expect(prefs.getString(key), isNull);

    await Future.wait(<Future<void>>[first, second]);
    final stored = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    expect(stored.keys, containsAll(<String>['a', 'b']));
  });

  test('flush writes a pending mark at once', () async {
    final marks = AgentReadMarks();
    final prefs = await SharedPreferences.getInstance();
    AgentReadMarks.persistDelay = const Duration(hours: 1);
    final pending = marks.markRead('a', when: DateTime.utc(2026, 1, 1));
    await marks.flush();
    await pending;
    expect(prefs.getString(key), contains('"a"'));
  });
}
