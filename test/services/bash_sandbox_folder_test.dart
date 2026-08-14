import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/bash_sandbox.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a fresh sandbox refuses commands until a folder is set', () {
    final sandbox = BashSandbox();
    expect(sandbox.isConfigured, isFalse);
    expect(sandbox.sandboxFolder, isNull);
  });

  test('setting a folder configures the sandbox and persists it', () async {
    final dir = await Directory.systemTemp.createTemp('sandbox_test');
    addTearDown(() => dir.delete(recursive: true));

    final sandbox = BashSandbox();
    await sandbox.setSandboxFolder(dir.path);

    expect(sandbox.isConfigured, isTrue);
    expect(sandbox.sandboxFolder, isNotNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('bash_sandbox_folder'), sandbox.sandboxFolder);

    // A second instance picks the folder back up on start.
    final restored = BashSandbox();
    await restored.loadSavedFolder();
    expect(restored.sandboxFolder, sandbox.sandboxFolder);
  });

  test('a folder that does not exist is rejected', () async {
    final sandbox = BashSandbox();
    await expectLater(
      sandbox.setSandboxFolder('/nope/not/here'),
      throwsA(isA<StateError>()),
    );
    expect(sandbox.isConfigured, isFalse);
  });

  test('clearing the folder refuses commands again', () async {
    final dir = await Directory.systemTemp.createTemp('sandbox_test');
    addTearDown(() => dir.delete(recursive: true));

    final sandbox = BashSandbox();
    await sandbox.setSandboxFolder(dir.path);
    await sandbox.clearSandboxFolder();

    expect(sandbox.isConfigured, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('bash_sandbox_folder'), isNull);
  });
}
