// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';

import 'package:chuk_chat/env_loader.dart';

// Same guard as test/flutter_test_config.dart: a test never loads the .env file.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  EnvLoader.skipFileForTests();
  await testMain();
}
