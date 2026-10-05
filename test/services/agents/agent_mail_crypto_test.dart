import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agent_mail_crypto.dart';

/// The seal format `chuk-agent-mail-v1` against the test vector of
/// docs/AGENT_MAIL.md §3.2: every implementation must open it, and must
/// produce it when the ephemeral key and the nonce are fixed.
void main() {
  List<int> hex(String s) => <int>[
    for (int i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];

  final List<int> recipientPrivate = hex(
    '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
  );
  const String recipientPublic = 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=';
  final List<int> ephemeralPrivate = hex(
    '65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384',
  );
  final List<int> nonce = hex('c9cacbcccdcecfd0d1d2d3d4');
  const String plaintext = 'hello agent mail ✓';
  const String textEnvelope =
      '{"v":1,"epk":"VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY=",'
      '"n":"ycrLzM3Oz9DR0tPU",'
      '"ct":"bPxiL4cAEjEH7OPALFms6fEudfWc8Wz6VHV5vyBhIkO5Cis9"}';
  const String binaryEnvelope =
      'Q0FNMVcUdp0Ra/dkNq50vHk9LDCtGQPFmsUnOAXH4mmLQQw2ycrLzM3Oz9DR0tPUbPxiL4cA'
      'EjEH7OPALFms6fEudfWc8Wz6VHV5vyBhIkO5Cis9';

  late AgentMailKeyPair recipient;

  setUpAll(() async {
    recipient = await AgentMailKeyPair.fromPrivateKey(recipientPrivate);
  });

  test('the recipient public key is derived from the private key', () {
    expect(recipient.publicKeyBase64, recipientPublic);
  });

  group('test vector', () {
    test('the text envelope opens', () async {
      expect(await unsealAgentMailText(textEnvelope, recipient), plaintext);
      // The server sends the envelope as a JSON object inside its field.
      expect(
        await unsealAgentMailText(jsonDecode(textEnvelope), recipient),
        plaintext,
      );
    });

    test('the binary envelope opens', () async {
      final Uint8List bytes = await unsealAgentMailBytes(
        base64Decode(binaryEnvelope),
        recipient,
      );
      expect(utf8.decode(bytes), plaintext);
    });

    test('fixed ephemeral key and nonce reproduce the text envelope', () async {
      final String sealed = await sealAgentMailText(
        plaintext,
        base64Decode(recipientPublic),
        ephemeralPrivateKey: ephemeralPrivate,
        nonce: nonce,
      );
      expect(sealed, textEnvelope);
    });

    test(
      'fixed ephemeral key and nonce reproduce the binary envelope',
      () async {
        final Uint8List sealed = await sealAgentMailBytes(
          utf8.encode(plaintext),
          base64Decode(recipientPublic),
          ephemeralPrivateKey: ephemeralPrivate,
          nonce: nonce,
        );
        expect(base64Encode(sealed), binaryEnvelope);
      },
    );
  });

  test('a fresh seal round-trips and is never the same twice', () async {
    final AgentMailKeyPair key = await AgentMailKeyPair.generate();
    final String a = await sealAgentMailText('{"subject":"Hi"}', key.publicKey);
    final String b = await sealAgentMailText('{"subject":"Hi"}', key.publicKey);
    expect(a, isNot(b));
    expect(await unsealAgentMailJson(a, key), <String, dynamic>{
      'subject': 'Hi',
    });
    final Uint8List blob = await sealAgentMailBytes(<int>[
      0,
      1,
      2,
      255,
    ], key.publicKey);
    expect(await unsealAgentMailBytes(blob, key), <int>[0, 1, 2, 255]);
  });

  group('a seal that does not open is an AgentMailSealException', () {
    Future<void> refused(Future<Object?> call) =>
        expectLater(call, throwsA(isA<AgentMailSealException>()));

    test('the wrong key', () async {
      final AgentMailKeyPair other = await AgentMailKeyPair.generate();
      await refused(unsealAgentMailText(textEnvelope, other));
      await refused(unsealAgentMailBytes(base64Decode(binaryEnvelope), other));
    });

    test('a changed ciphertext byte', () async {
      final Map<String, dynamic> env =
          jsonDecode(textEnvelope) as Map<String, dynamic>;
      final List<int> ct = base64Decode(env['ct'] as String);
      ct[0] ^= 1;
      env['ct'] = base64Encode(ct);
      await refused(unsealAgentMailText(env, recipient));
    });

    test('a bad shape', () async {
      await refused(unsealAgentMailText(null, recipient));
      await refused(unsealAgentMailText('not json', recipient));
      await refused(unsealAgentMailText(<String, dynamic>{'v': 2}, recipient));
      await refused(
        unsealAgentMailText(<String, dynamic>{
          'v': 1,
          'epk': '!!',
          'n': 'AA==',
          'ct': 'AA==',
        }, recipient),
      );
      await refused(unsealAgentMailBytes(<int>[1, 2, 3], recipient));
      final List<int> wrongMagic = base64Decode(binaryEnvelope)..[0] = 0;
      await refused(unsealAgentMailBytes(wrongMagic, recipient));
      // A text seal whose plaintext is not a JSON object.
      await refused(unsealAgentMailJson(textEnvelope, recipient));
    });
  });
}
