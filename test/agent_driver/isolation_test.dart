// Safety rules of the agent driver: own data folders, local stack only.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/agent_driver/src/isolation.dart';

void main() {
  const String scratch = '/repo/_scratch';
  final AppHome home = AppHome(p.join(scratch, 'agent_home'));

  group('isolatedEnvironment', () {
    test('sets the XDG folders under the app home and multi-instance', () {
      final Map<String, String> env = isolatedEnvironment(
        base: <String, String>{'HOME': '/home/u', 'PATH': '/bin'},
        home: home,
        scratchDir: scratch,
      );
      expect(env['XDG_DATA_HOME'], '/repo/_scratch/agent_home/data');
      expect(env['XDG_CACHE_HOME'], '/repo/_scratch/agent_home/cache');
      expect(env['XDG_STATE_HOME'], '/repo/_scratch/agent_home/state');
      expect(env['CHUK_MULTI_INSTANCE'], '1');
      expect(env['PATH'], '/bin');
    });

    test('replaces XDG folders that the parent environment sets', () {
      final Map<String, String> env = isolatedEnvironment(
        base: <String, String>{'XDG_DATA_HOME': '/home/u/.local/share'},
        home: home,
        scratchDir: scratch,
      );
      expect(env['XDG_DATA_HOME'], home.data);
    });

    test('refuses a home outside the scratch folder', () {
      expect(
        () => isolatedEnvironment(
          base: const <String, String>{},
          home: AppHome('/home/u/.local'),
          scratchDir: scratch,
        ),
        throwsA(isA<IsolationError>()),
      );
    });

    test('refuses the scratch folder itself as the home', () {
      expect(
        () => isolatedEnvironment(
          base: const <String, String>{},
          home: AppHome(scratch),
          scratchDir: scratch,
        ),
        throwsA(isA<IsolationError>()),
      );
    });
  });

  group('checkLocalDefines', () {
    test('accepts loopback addresses', () {
      checkLocalDefines(<String, Object?>{
        'API_BASE_URL': 'http://127.0.0.1:8797',
        'SUPABASE_URL': 'http://localhost:54321',
      });
    });

    test('refuses production and missing values', () {
      expect(
        () => checkLocalDefines(<String, Object?>{
          'API_BASE_URL': 'https://api.chuk.chat',
          'SUPABASE_URL': 'http://127.0.0.1:54321',
        }),
        throwsA(isA<IsolationError>()),
      );
      expect(
        () => checkLocalDefines(<String, Object?>{
          'API_BASE_URL': 'http://127.0.0.1:8797',
        }),
        throwsA(isA<IsolationError>()),
      );
    });

    test('refuses any other URL define that points away from loopback', () {
      const Map<String, Object?> base = <String, Object?>{
        'API_BASE_URL': 'http://127.0.0.1:8797',
        'SUPABASE_URL': 'http://127.0.0.1:54321',
      };
      for (final String key in <String>[
        ...optionalUrlDefines,
        'API_HOST',
      ]) {
        final String bad =
            key == 'API_HOST' ? 'api.chuk.chat' : 'https://api.chuk.chat';
        expect(
          () => checkLocalDefines(<String, Object?>{...base, key: bad}),
          throwsA(isA<IsolationError>()),
          reason: key,
        );
      }
    });

    test('refuses the Linux keyring', () {
      expect(
        () => checkLocalDefines(<String, Object?>{
          'API_BASE_URL': 'http://127.0.0.1:8797',
          'SUPABASE_URL': 'http://127.0.0.1:54321',
          'FEATURE_LINUX_KEYRING': true,
        }),
        throwsA(isA<IsolationError>()),
      );
      checkLocalDefines(<String, Object?>{
        'API_BASE_URL': 'http://127.0.0.1:8797',
        'SUPABASE_URL': 'http://127.0.0.1:54321',
        'FEATURE_LINUX_KEYRING': 'false',
      });
    });

    test('accepts empty or loopback optional URL defines', () {
      checkLocalDefines(<String, Object?>{
        'API_BASE_URL': 'http://127.0.0.1:8797',
        'SUPABASE_URL': 'http://127.0.0.1:54321',
        'PRODUCTION_API_URL': '',
        'AGENTS_RELAY_URL': 'ws://127.0.0.1:8797',
        'API_HOST': 'localhost',
      });
    });
  });
}
