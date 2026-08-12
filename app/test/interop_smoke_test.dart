// Cross-language interop smoke: the real Dart CoworkRelayClient against a LIVE
// Python `cowork-host`. Two env-gated halves, so one host can be driven through
// the whole persistent-pairing story from separate Dart VMs (a real app restart,
// not a fake one).
//
//   1. PAIR — needs COWORK_HOST_URL + COWORK_PAIRING_CODE + COWORK_TRUST_FILE.
//      Runs the §15 joiner ceremony from the code, provisions, runs a task, and
//      writes what a real app would keep in secure storage (its device seed +
//      the trust record) to COWORK_TRUST_FILE.
//   2. RECONNECT — needs COWORK_HOST_URL + COWORK_TRUST_FILE (and NO code).
//      Rebuilds the client from that file alone — a cold app start — and
//      reconnects with the signed handshake, no code, then runs another task.
//
//   cd ../host && uv run cowork-host --mock-model --port 8795 &   # prints a code
//   COWORK_HOST_URL=ws://127.0.0.1:8795 COWORK_PAIRING_CODE=<code> \
//     COWORK_TRUST_FILE=/path/trust.json flutter test test/interop_smoke_test.dart
//   # restart the host, then:
//   COWORK_HOST_URL=ws://127.0.0.1:8795 COWORK_TRUST_FILE=/path/trust.json \
//     flutter test test/interop_smoke_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// A plain web_socket_channel-backed [RelaySocket] — bypasses the cert-pinned
/// production connector, which is irrelevant for a localhost ws:// host.
class _PlainSocket implements RelaySocket {
  _PlainSocket(this._ch);
  final WebSocketChannel _ch;
  @override
  Stream get incoming => _ch.stream;
  @override
  void send(String data) => _ch.sink.add(data);
  @override
  Future<void> close() => _ch.sink.close();
}

Future<RelaySocket> _plainConnector(Uri url) async {
  final ch = WebSocketChannel.connect(url);
  await ch.ready;
  return _PlainSocket(ch);
}

const _session = AccountSession(
  accessToken: 'mock',
  refreshToken: 'mock',
  userId: 'mock',
);

/// Drives one run to completion and returns the tool events it saw.
Future<List<CoworkRelayTool>> _runTask(
  CoworkRelayClient client,
  String prompt,
) async {
  final done = Completer<void>();
  final tools = <CoworkRelayTool>[];
  final sub = client.inbound.listen((e) {
    if (e is CoworkRelayTool) {
      tools.add(e);
    } else if (e is CoworkRelayDone && !done.isCompleted) {
      done.complete();
    } else if (e is CoworkRelayRunError && !done.isCompleted) {
      done.completeError(StateError('agent error: ${e.message}'));
    }
  });
  await client.provisionAccount(_session);
  await client.sendTask(prompt);
  try {
    await done.future.timeout(const Duration(seconds: 40));
  } finally {
    await sub.cancel();
  }
  return tools;
}

void main() {
  final url = Platform.environment['COWORK_HOST_URL'];
  final code = Platform.environment['COWORK_PAIRING_CODE'];
  final trustPath = Platform.environment['COWORK_TRUST_FILE'];

  test('1. pairs with the live Python host from a code and stores the trust',
      () async {
    if (url == null || code == null || trustPath == null) {
      markTestSkipped('set COWORK_HOST_URL + COWORK_PAIRING_CODE + '
          'COWORK_TRUST_FILE');
      return;
    }

    // A stable device identity, exactly as CoworkPairingStore would mint it.
    final keyPair = await CoworkDeviceKeys.generate();
    const deviceId = 'smoke-desktop';
    final client = CoworkRelayClient(
      deviceId: deviceId,
      signingKeyPair: keyPair,
      connector: _plainConnector,
    );

    await client.connect(hostUrl: Uri.parse(url), pairingCode: code);
    expect(client.state.value.isPaired, isTrue, reason: 'pairing must succeed');

    final trust = client.establishedTrust;
    expect(trust, isNotNull, reason: 'pairing must yield a persistable trust');

    final tools = await _runTask(client, 'run the demo command');
    expect(tools, isNotEmpty, reason: 'the mock agent runs one command');

    // Persist what the app keeps in secure storage: the device seed + the trust.
    await File(trustPath).writeAsString(
      jsonEncode(<String, dynamic>{
        'device_id': deviceId,
        'seed_b64': await CoworkDeviceKeys.exportPrivateKeySeedBase64(keyPair),
        'pairing': trust!.toJson(),
      }),
    );

    await client.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('2. a cold restart reconnects with NO code and runs another task',
      () async {
    if (url == null || trustPath == null || code != null) {
      markTestSkipped('set COWORK_HOST_URL + COWORK_TRUST_FILE and NO '
          'COWORK_PAIRING_CODE');
      return;
    }
    final file = File(trustPath);
    expect(file.existsSync(), isTrue, reason: 'run the pairing half first');

    // Cold start: everything comes from storage, nothing from a human.
    final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final keyPair =
        await CoworkDeviceKeys.fromSeedBase64(saved['seed_b64'] as String);
    final stored = CoworkStoredPairing.tryParse(jsonEncode(saved['pairing']));
    expect(stored, isNotNull, reason: 'the stored trust must parse back');

    final client = CoworkRelayClient(
      deviceId: saved['device_id'] as String,
      signingKeyPair: keyPair,
      connector: _plainConnector,
    );

    await client.reconnect(hostUrl: Uri.parse(url), pairing: stored!);
    expect(client.state.value.isPaired, isTrue,
        reason: 'the signed reconnect must authenticate with no code');
    expect(client.state.value.peerDeviceId, stored.peerDeviceId);

    final tools = await _runTask(client, 'run the demo command again');
    expect(tools, isNotEmpty, reason: 'tasks must run after a code-free resume');

    await client.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('3. an imposter device is refused by the live host', () async {
    if (url == null || trustPath == null || code != null) {
      markTestSkipped('set COWORK_HOST_URL + COWORK_TRUST_FILE and NO '
          'COWORK_PAIRING_CODE');
      return;
    }
    final file = File(trustPath);
    expect(file.existsSync(), isTrue, reason: 'run the pairing half first');
    final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final stored = CoworkStoredPairing.tryParse(jsonEncode(saved['pairing']))!;

    // Everything stolen — channel id, channel key, the host's public key, the
    // device id — except the app's long-term private key. That one gap is the
    // whole security of the reconnect, so this must fail against the LIVE host.
    final imposterKey = await CoworkDeviceKeys.generate();
    final client = CoworkRelayClient(
      deviceId: saved['device_id'] as String,
      signingKeyPair: imposterKey,
      connector: _plainConnector,
      pairingTimeout: const Duration(seconds: 8),
    );

    await expectLater(
      client.reconnect(hostUrl: Uri.parse(url), pairing: stored),
      throwsA(anything),
      reason: 'a forged device key must never resume the channel',
    );
    expect(client.state.value.isPaired, isFalse);
    await client.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));
}
