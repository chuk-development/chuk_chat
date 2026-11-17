import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/notifications/sealed_preview.dart';

/// Test vector made with Python `cryptography` (AESGCM) and `hmac`, the
/// same libraries the host uses:
///
///   channel_key = bytes(range(32))
///   push_key    = hmac.digest(channel_key, b"cowork/push/preview/v1", "sha256")
///   nonce       = bytes(range(100, 112))
///   sealed      = b64(nonce + AESGCM(push_key).encrypt(nonce, plaintext, None))
final List<int> _channelKey = List<int>.generate(32, (int i) => i);
const String _pushKeyHex =
    'bf24d707c4f25e9fcc144ddf730cac87c573cc2592c7fe4bf33d28f094122bb0';
const String _sealed =
    'ZGVmZ2hpamtsbW5vvcI2qUWBFJbOYzGe18Q42ewEa2sjZnYIwkTVsj3hDhBidzWAHrmH6/EI'
    '2MdjDBMcLa34aAuZmY7EBaJ58s2S2vhAH91dzCOJQcTojd2H/eu1u4vF2fXQPk4HdWQqHk7N'
    'bgvP7Z8j+QvEl5KA1IW8bNnBHiZrK+5/muvWTCkT+uExBBC16s22e781c1lkbpdGKeba/tfd'
    'n/XZK9I=';

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('push key = HMAC-SHA256(channel key, label)', () async {
    expect(_hex(await derivePushPreviewKey(_channelKey)), _pushKeyHex);
  });

  test('opens the Python test vector', () async {
    final SealedPreview? opened = await openSealedPreview(_sealed, _channelKey);
    expect(opened, isNotNull);
    expect(opened!.title, 'Research');
    expect(opened.body, 'Der Bericht ist fertig. Drei Quellen …');
    expect(opened.agentId, 'agent-7');
    expect(opened.sessionKey, 'agent-7');
    expect(opened.runId, 'run-42');
  });

  test('opens the host test vector (docs/agents/NOTIFICATIONS.md)', () async {
    // Pinned on the host side by agents/host/tests/test_push_preview.py.
    const String hostSealed =
        'EBESExQVFhcYGRobFu8WALfXR0Ufwdw2EGA8/XP1RQSZwRI2J/aV1yljHdoStej4/sBO'
        'VhkBCnGVsSSD5teX4UQWLBhsNC+GYAj0zd1zvgZ1pcTzc7ZPvtfqyDKiY/i9jJkcbC2x'
        'k6z57JjqPIiRF4s93fCfn55JMDKRVCM3NQCXvtFWItO+xmoed3IOPVDSDG7OYSw=';
    final List<int> raw = base64.decode(hostSealed);
    expect(_hex(raw.sublist(0, 12)), '101112131415161718191a1b');
    final SealedPreview? opened = await openSealedPreview(
      hostSealed,
      _channelKey,
    );
    expect(opened, isNotNull);
    expect(opened!.title, 'Ada');
    expect(opened.body, 'Die Summe ist 210. Sch\u00f6n!');
    expect(opened.agentId, 'local:a1');
    expect(opened.sessionKey, 'local:a1');
    expect(opened.runId, 'run-1');
  });

  test('a wrong key does not open (tag check)', () async {
    final List<int> wrong = List<int>.of(_channelKey)..[0] ^= 1;
    expect(await openSealedPreview(_sealed, wrong), isNull);
  });

  test('a changed byte does not open', () async {
    final List<int> raw = base64.decode(_sealed);
    raw[20] ^= 1;
    expect(await openSealedPreview(base64.encode(raw), _channelKey), isNull);
  });

  test('junk does not open and does not throw', () async {
    expect(await openSealedPreview('', _channelKey), isNull);
    expect(await openSealedPreview('not base64 !!', _channelKey), isNull);
    expect(await openSealedPreview('AAAA', _channelKey), isNull);
  });

  test('round trip with a fresh nonce', () async {
    final List<int> key = await derivePushPreviewKey(_channelKey);
    final SecretBox box = await AesGcm.with256bits().encrypt(
      utf8.encode(
        jsonEncode(<String, Object>{
          'v': 1,
          'title': 'T',
          'body': 'B',
          'agent_id': 'a',
          'session_key': 's',
          'run_id': 'r',
        }),
      ),
      secretKey: SecretKey(key),
    );
    final String sealed = base64.encode(<int>[
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    final SealedPreview? opened = await openSealedPreview(sealed, _channelKey);
    expect(opened?.title, 'T');
    expect(opened?.body, 'B');
  });

  test('another version is refused', () {
    expect(
      SealedPreview.fromJson(<String, Object>{
        'v': 2,
        'title': 'a',
        'body': 'b',
      }),
      isNull,
    );
    expect(
      SealedPreview.fromJson(<String, Object>{'v': 1, 'title': 'a'}),
      isNull,
    );
  });

  group('openPreviewFromPushData', () {
    test('reads the map as JSON text (FCM data values are strings)', () async {
      final SealedPreview? opened = await openPreviewFromPushData(
        <String, Object>{
          'preview_sealed': jsonEncode(<String, String>{
            'other-channel': 'xxxx',
            'chan-1': _sealed,
          }),
        },
        channelId: 'chan-1',
        channelKey: _channelKey,
      );
      expect(opened?.title, 'Research');
    });

    test('reads a real map (UnifiedPush JSON body)', () async {
      final SealedPreview? opened = await openPreviewFromPushData(
        <String, Object>{
          'preview_sealed': <String, String>{'chan-1': _sealed},
        },
        channelId: 'chan-1',
        channelKey: _channelKey,
      );
      expect(opened?.runId, 'run-42');
    });

    test('no value for this channel: null', () async {
      expect(
        await openPreviewFromPushData(
          <String, Object>{
            'preview_sealed': jsonEncode(<String, String>{'other': _sealed}),
          },
          channelId: 'chan-1',
          channelKey: _channelKey,
        ),
        isNull,
      );
      expect(
        await openPreviewFromPushData(
          <String, Object>{'preview_sealed': '{not json'},
          channelId: 'chan-1',
          channelKey: _channelKey,
        ),
        isNull,
      );
      expect(
        await openPreviewFromPushData(
          <String, Object>{},
          channelId: 'chan-1',
          channelKey: _channelKey,
        ),
        isNull,
      );
    });
  });
}
