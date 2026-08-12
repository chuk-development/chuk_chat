// Cross-language interop smoke: the real Dart CoworkRelayClient against a LIVE
// Python `cowork-host` (started separately with --mock-model). Skipped unless
// COWORK_HOST_URL + COWORK_PAIRING_CODE are set in the environment.
//
//   cd ../host && uv run cowork-host --mock-model --port 8790 &   # prints a code
//   COWORK_HOST_URL=ws://127.0.0.1:8790 COWORK_PAIRING_CODE=<code> \
//     flutter test test/interop_smoke_test.dart
import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:cowork/services/account_session.dart';
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

void main() {
  final url = Platform.environment['COWORK_HOST_URL'];
  final code = Platform.environment['COWORK_PAIRING_CODE'];

  test('Dart client pairs with the live Python host and runs a task', () async {
    if (url == null || code == null) {
      markTestSkipped('set COWORK_HOST_URL + COWORK_PAIRING_CODE');
      return;
    }

    final kp = await Ed25519().newKeyPair();
    final client = CoworkRelayClient(
      deviceId: 'smoke-desktop',
      signingKeyPair: kp,
      connector: _plainConnector,
    );

    final done = Completer<CoworkRelayDone>();
    final tools = <CoworkRelayTool>[];
    final deltas = StringBuffer();
    final sub = client.inbound.listen((e) {
      if (e is CoworkRelayDelta) {
        deltas.write(e.text);
      } else if (e is CoworkRelayTool) {
        tools.add(e);
      } else if (e is CoworkRelayDone && !done.isCompleted) {
        done.complete(e);
      }
    });

    await client.connect(hostUrl: Uri.parse(url), pairingCode: code);
    expect(client.state.value.isPaired, isTrue, reason: 'pairing must succeed');

    await client.provisionAccount(
      const AccountSession(
        accessToken: 'mock',
        refreshToken: 'mock',
        userId: 'mock',
      ),
    );
    await client.sendTask('run the demo command');

    final result = await done.future.timeout(const Duration(seconds: 40));
    expect(result, isNotNull);
    // The mock agent runs one run_command tool, so at least one tool arrived.
    expect(tools, isNotEmpty, reason: 'the mock agent runs one command');

    await sub.cancel();
    client.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));
}
