import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/api_config_base.dart';

/// The Agents relay follows the configured API base, so one dart-define points
/// the whole app at a local API emulator. With no defines it must stay the
/// exact production string.
void main() {
  group('resolveAgentsRelayBase', () {
    test('the production API gives the production relay, byte for byte', () {
      expect(
        resolveAgentsRelayBase(apiBaseUrl: 'https://api.chuk.chat'),
        'wss://api.chuk.chat',
      );
      expect(
        resolveAgentsRelayBase(apiBaseUrl: apiConfigDefaultProductionUrl),
        agentsRelayDefaultBaseUrl,
      );
    });

    test('a non-loopback http or ws host keeps TLS', () {
      expect(
        resolveAgentsRelayBase(apiBaseUrl: 'http://192.168.1.5:8000'),
        'wss://192.168.1.5:8000',
      );
      expect(
        resolveAgentsRelayBase(
          apiBaseUrl: 'https://api.chuk.chat',
          override: 'ws://relay.example.com',
        ),
        'wss://relay.example.com',
      );
      expect(
        agentsHttpOriginForRelay(
          resolveAgentsRelayBase(apiBaseUrl: 'http://192.168.1.5:8000'),
        ),
        'https://192.168.1.5:8000',
      );
    });

    test('a local http emulator gives a plain ws relay with its port', () {
      expect(
        resolveAgentsRelayBase(apiBaseUrl: 'http://127.0.0.1:8787'),
        'ws://127.0.0.1:8787',
      );
      expect(
        resolveAgentsRelayBase(apiBaseUrl: 'http://localhost:8000/'),
        'ws://localhost:8000',
      );
    });

    test('https keeps an explicit port and drops any path', () {
      expect(
        resolveAgentsRelayBase(
          apiBaseUrl: 'https://staging.example.test:8443/v1',
        ),
        'wss://staging.example.test:8443',
      );
    });

    test('AGENTS_RELAY_URL wins over the API base', () {
      expect(
        resolveAgentsRelayBase(
          apiBaseUrl: 'https://api.chuk.chat',
          override: 'ws://127.0.0.1:9999',
        ),
        'ws://127.0.0.1:9999',
      );
      expect(
        resolveAgentsRelayBase(
          apiBaseUrl: 'https://api.chuk.chat',
          override: 'http://127.0.0.1:8787',
        ),
        'ws://127.0.0.1:8787',
      );
    });

    test('an unusable override or base falls back, never half-builds', () {
      expect(
        resolveAgentsRelayBase(
          apiBaseUrl: 'http://127.0.0.1:8787',
          override: 'ftp://nope',
        ),
        'ws://127.0.0.1:8787',
      );
      expect(
        resolveAgentsRelayBase(apiBaseUrl: 'ftp://nope'),
        agentsRelayDefaultBaseUrl,
      );
      expect(resolveAgentsRelayBase(apiBaseUrl: ''), agentsRelayDefaultBaseUrl);
    });
  });

  group('agentsHttpOriginForRelay', () {
    test('maps the relay back to the API origin', () {
      expect(
        agentsHttpOriginForRelay('wss://api.chuk.chat'),
        'https://api.chuk.chat',
      );
      expect(
        agentsHttpOriginForRelay('ws://127.0.0.1:8787'),
        'http://127.0.0.1:8787',
      );
    });
  });

  group('build wiring', () {
    test('the relay constant is the resolved relay for this build', () {
      expect(kDefaultAgentsRelayBase, getAgentsRelayBaseUrl());
      expect(
        Uri.parse(kAgentsInstallScriptUrl).host,
        Uri.parse(kDefaultAgentsRelayBase).host,
      );
    });

    test(
      'with no defines the relay and installer are the production values',
      () {
        expect(getAgentsRelayBaseUrl(), 'wss://api.chuk.chat');
        expect(kDefaultAgentsRelayBase, 'wss://api.chuk.chat');
        expect(
          kAgentsInstallScriptUrl,
          'https://api.chuk.chat/agents/install.sh',
        );
      },
      skip: getConfiguredUrl() != null || apiConfigAgentsRelayUrl.isNotEmpty
          ? 'API or relay dart-define set for this run'
          : false,
    );
  });
}
