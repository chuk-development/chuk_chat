@TestOn('vm')
library;

import 'dart:io';

import 'package:chuk_chat/tool_handlers/cowork_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  final savedTimeout = coworkCommandTimeout;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cowork_jail_');
    coworkJailRoot = root.path;
    coworkCommandTimeout = savedTimeout;
  });

  tearDown(() {
    coworkJailRoot = '';
    coworkCommandTimeout = savedTimeout;
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('write_file / read_file happy path', () {
    test('writes then reads back the same content', () async {
      final write = await executeWriteFile({
        'path': 'notes/hello.txt',
        'content': 'hello cowork',
      });
      expect(write, contains('Wrote'));
      expect(File(p.join(root.path, 'notes', 'hello.txt')).existsSync(), isTrue);

      final read = await executeReadFile({'path': 'notes/hello.txt'});
      expect(read, 'hello cowork');
    });

    test('read of a large file is truncated and says so', () async {
      final big = 'x' * (250 * 1024); // > 200 KB cap
      File(p.join(root.path, 'big.txt')).writeAsStringSync(big);
      final read = await executeReadFile({'path': 'big.txt'});
      expect(read, contains('truncated'));
      expect(read.length, lessThan(big.length));
    });

    test('missing file returns an error', () async {
      final read = await executeReadFile({'path': 'nope.txt'});
      expect(read, startsWith('Error:'));
    });
  });

  group('list_directory', () {
    test('lists entries with type markers', () async {
      File(p.join(root.path, 'a.txt')).writeAsStringSync('a');
      Directory(p.join(root.path, 'sub')).createSync();
      final list = await executeListDirectory({'path': '.'});
      expect(list, contains('a.txt'));
      expect(list, contains('sub/ (dir)'));
    });
  });

  group('run_command happy path', () {
    test('captures stdout and exit code', () async {
      final out = await executeRunCommand({'command': 'echo cowork_ok'});
      expect(out, contains('exit_code: 0'));
      expect(out, contains('cowork_ok'));
    });
  });

  group('jail escape rejected', () {
    test('read_file with ../ escape is rejected', () async {
      final read = await executeReadFile({'path': '../../etc/hosts'});
      expect(read, startsWith('Error:'));
      expect(read, contains('escapes the CoWork root'));
    });

    test('write_file with absolute path outside root is rejected', () async {
      final outside = p.join(Directory.systemTemp.path, 'cowork_escape.txt');
      final write = await executeWriteFile({
        'path': outside,
        'content': 'nope',
      });
      expect(write, startsWith('Error:'));
      expect(File(outside).existsSync(), isFalse);
    });

    test('run_command cwd outside root is rejected', () async {
      final out = await executeRunCommand({
        'command': 'echo hi',
        'cwd': '../../',
      });
      expect(out, startsWith('Error:'));
      expect(out, contains('escapes the CoWork root'));
    });

    test('a symlink pointing outside the root cannot be read through', () async {
      // A secret file lives OUTSIDE the jail. A symlink inside the jail points
      // at it. Reading through the symlink must be rejected by the jail.
      final secretDir = Directory.systemTemp.createTempSync('cowork_secret_');
      addTearDown(() {
        if (secretDir.existsSync()) secretDir.deleteSync(recursive: true);
      });
      final secret = File(p.join(secretDir.path, 'secret.txt'))
        ..writeAsStringSync('top secret');
      final link = Link(p.join(root.path, 'leak.txt'));
      link.createSync(secret.path);

      final read = await executeReadFile({'path': 'leak.txt'});
      expect(read, startsWith('Error:'));
      expect(read, contains('escapes the CoWork root'));
    });
  });

  group('credential denylist rejected', () {
    test('.env read is refused', () async {
      File(p.join(root.path, '.env')).writeAsStringSync('SECRET=1');
      final read = await executeReadFile({'path': '.env'});
      expect(read, startsWith('Error:'));
      expect(read, contains('denylist'));
    });

    test('*.pem read is refused', () async {
      File(p.join(root.path, 'server.pem')).writeAsStringSync('KEY');
      final read = await executeReadFile({'path': 'server.pem'});
      expect(read, contains('denylist'));
    });

    test('id_rsa read is refused', () async {
      Directory(p.join(root.path, '.ssh')).createSync();
      File(p.join(root.path, '.ssh', 'id_rsa')).writeAsStringSync('KEY');
      final read = await executeReadFile({'path': '.ssh/id_rsa'});
      expect(read, contains('denylist'));
    });

    test('.aws/credentials read is refused', () async {
      Directory(p.join(root.path, '.aws')).createSync();
      File(p.join(root.path, '.aws', 'credentials'))
          .writeAsStringSync('[default]');
      final read = await executeReadFile({'path': '.aws/credentials'});
      expect(read, contains('denylist'));
    });
  });

  group('run_command timeout', () {
    test('a long command is killed and returns a timeout error', () async {
      coworkCommandTimeout = const Duration(milliseconds: 300);
      final out = await executeRunCommand({'command': 'sleep 5'});
      expect(out, startsWith('Error:'));
      expect(out, contains('timed out'));
    });
  });
}
