import 'dart:async';

import 'package:chuk_chat/env_loader.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';

/// Runs before every test file.
///
/// [AgentReadMarks] writes its marks to disk a moment after the last change,
/// so a burst costs one preference write. A widget test must not end with that
/// write still waiting on a timer, so tests write at once; the one test that
/// checks the delay sets it back itself.
///
/// The `.env` file is never loaded in a test: a developer machine has one and
/// CI has none, and a test must see the same app in both places.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  EnvLoader.skipFileForTests();
  AgentReadMarks.persistDelay = Duration.zero;
  await testMain();
}
