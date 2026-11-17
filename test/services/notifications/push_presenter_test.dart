import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/notifications/local_notifications.dart';
import 'package:chuk_chat/services/notifications/push_presenter.dart';
import 'package:chuk_chat/services/notifications/sealed_preview.dart';

import 'local_notifications_test.dart' show FakeBackend;

final Uint8List _channelKey = Uint8List.fromList(
  List<int>.generate(32, (int i) => 255 - i),
);

Future<String> _seal(Map<String, Object> plain) async {
  final SecretBox box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(plain)),
    secretKey: SecretKey(await derivePushPreviewKey(_channelKey)),
  );
  return base64.encode(<int>[
    ...box.nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

Future<AgentsStoredPairing> _pairing() async => AgentsStoredPairing(
  hostUrl: Uri.parse('wss://example.invalid/v2/relay/ws'),
  channelId: 'chan-1',
  channelKey: _channelKey,
  peerDeviceId: 'host-1',
  peerPublicKey: await (await Ed25519().newKeyPair()).extractPublicKey(),
);

void main() {
  late FakeBackend backend;
  late Map<String, Object> data;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocalNotifications.instance.reset();
    backend = FakeBackend();
    await LocalNotifications.instance.initialize(backend: backend);
    data = <String, Object>{
      'session_key': 'agent-7',
      'run_id': 'run-1',
      'title': 'Your agent',
      'body': 'The answer is ready. Open the app to read it.',
      'preview_sealed': jsonEncode(<String, String>{
        'chan-1': await _seal(<String, Object>{
          'v': 1,
          'title': 'Research',
          'body': 'Drei Quellen gefunden.',
          'agent_id': 'agent-7',
          'session_key': 'agent-7',
          'run_id': 'run-1',
        }),
      }),
    };
  });

  tearDown(() => LocalNotifications.instance.reset());

  Future<void> present({
    Future<AgentsStoredPairing?> Function()? loadPairing,
    bool Function(String)? isVisible,
  }) => PushPresenter.present(
    data,
    loadPairing: loadPairing ?? _pairing,
    isVisible: isVisible,
    avatarLookup: (String id) async =>
        id == 'agent-7' ? '/a/agent-7.png' : null,
  );

  test('opens the seal: agent name, preview body, face', () async {
    await present();
    final Map<String, Object?> shown = backend.shown.single;
    expect(shown['title'], 'Research');
    expect(shown['body'], 'Drei Quellen gefunden.');
    expect(shown['icon'], '/a/agent-7.png');
    expect(shown['tag'], 'agent-7');
    expect(jsonDecode(shown['payload']! as String), <String, String>{
      'session_key': 'agent-7',
      'run_id': 'run-1',
    });
  });

  test('no pairing: the generic text from the data', () async {
    await present(loadPairing: () async => null);
    final Map<String, Object?> shown = backend.shown.single;
    expect(shown['title'], 'Your agent');
    expect(shown['body'], 'The answer is ready. Open the app to read it.');
  });

  test('a pairing that throws (locked storage): the generic text', () async {
    await present(loadPairing: () async => throw StateError('locked'));
    expect(backend.shown.single['title'], 'Your agent');
  });

  test('preview setting off: the name but the generic body', () async {
    await LocalNotifications.setAnswerPreviewEnabled(false);
    await present();
    expect(backend.shown.single['title'], 'Research');
    expect(
      backend.shown.single['body'],
      'The answer is ready. Open the app to read it.',
    );
  });

  test('a thread on screen shows nothing', () async {
    await present(isVisible: (String key) => key == 'agent-7');
    expect(backend.shown, isEmpty);
  });

  test('no thread named: nothing', () async {
    data.remove('session_key');
    data.remove('preview_sealed');
    await present();
    expect(backend.shown, isEmpty);
  });

  test('textFor: missing fallback text uses safe defaults', () {
    final PushToastText? text = PushPresenter.textFor(<String, Object>{
      'session_key': 's',
    }, previewOn: true);
    expect(text?.title, 'Chuk Chat');
    expect(text?.body, LocalNotifications.defaultBody);
  });

  test('textFor: an overlong body is clipped', () {
    final PushToastText? text = PushPresenter.textFor(
      <String, Object>{'session_key': 's'},
      opened: SealedPreview(title: 't', body: 'x' * 1000),
      previewOn: true,
    );
    expect(text!.body.length, kMaxPushBodyChars);
    expect(text.body.endsWith('…'), isTrue);
  });
}
