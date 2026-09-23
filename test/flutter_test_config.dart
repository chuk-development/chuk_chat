import 'dart:async';

import 'package:chuk_chat/services/agents/agent_read_marks.dart';

/// Runs before every test file.
///
/// [AgentReadMarks] writes its marks to disk a moment after the last change,
/// so a burst costs one preference write. A widget test must not end with that
/// write still waiting on a timer, so tests write at once; the one test that
/// checks the delay sets it back itself.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AgentReadMarks.persistDelay = Duration.zero;
  await testMain();
}
