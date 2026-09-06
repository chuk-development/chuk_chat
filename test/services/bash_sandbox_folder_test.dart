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

  group('symlink containment', () {
    late Directory sandboxDir;
    late Directory outsideDir;
    late BashSandbox sandbox;

    setUp(() async {
      sandboxDir = await Directory.systemTemp.createTemp('sandbox_root');
      outsideDir = await Directory.systemTemp.createTemp('sandbox_outside');
      sandbox = BashSandbox();
      await sandbox.setSandboxFolder(sandboxDir.path);
    });

    tearDown(() async {
      await sandboxDir.delete(recursive: true);
      await outsideDir.delete(recursive: true);
    });

    test('a plain path inside the folder is allowed', () async {
      expect(sandbox.isWithinSandbox('touch inside.txt'), isTrue);
    });

    test('an absolute path outside the folder is refused', () async {
      expect(
        sandbox.isWithinSandbox('touch ${outsideDir.path}/escape.txt'),
        isFalse,
      );
    });

    test('writing through a symlinked directory is refused', () async {
      final link = Link('${sandboxDir.path}/link');
      await link.create(outsideDir.path);

      // The target does not exist yet, so containment has to be judged on
      // the link it would be created through.
      expect(sandbox.isWithinSandbox('touch link/new.txt'), isFalse);
    });

    test('reading through a symlink to an outside file is refused', () async {
      final secret = File('${outsideDir.path}/secret.txt');
      await secret.writeAsString('nope');
      final link = Link('${sandboxDir.path}/secret_link');
      await link.create(secret.path);

      expect(sandbox.isWithinSandbox('cat secret_link'), isFalse);
    });
  });
}
