import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_pairing_uri.dart';

/// The one string the user ever handles. It comes off a QR code, out of a
/// paste, or off a keyboard, and every one of those routes has to end at the
/// same channel, the same §15 code and the same relay — or land on null, which
/// the screen shows as "try again". Nothing in between.
void main() {
  const String channel =
      'kx7m2p9q4w8r3t6y1u5i0o2a7s4d9f3g6h1j8k5l2z7x4c9v6b3n8m1q4w7e';

  group('CoworkPairingInvite.tryParse', () {
    test('reads the full pairing URI the host prints', () {
      final invite = CoworkPairingInvite.tryParse(
        'cowork://pair?c=$channel&k=428913',
      );

      expect(invite, isNotNull);
      expect(invite!.pairingChannel, channel);
      // The ceremony wants `<channel>-<digits>`; the URI carries them apart.
      expect(invite.pairingCode, '$channel-428913');
      expect(invite.codeDigits, '428913');
      expect(invite.relayBase, Uri.parse(kDefaultCoworkRelayBase));
    });

    test('an explicit relay points a self-hosted backend at itself', () {
      final invite = CoworkPairingInvite.tryParse(
        'cowork://pair?c=$channel&k=428913&r=wss://relay.example.test',
      );

      expect(invite!.relayBase, Uri.parse('wss://relay.example.test'));
    });

    test('https and a bare host are normalised to a websocket base', () {
      expect(
        CoworkPairingInvite.tryParse(
          'cowork://pair?c=$channel&k=1&r=https://api.chuk.chat',
        )!.relayBase,
        Uri.parse('wss://api.chuk.chat'),
      );
      expect(
        CoworkPairingInvite.tryParse(
          'cowork://pair?c=$channel&k=1&r=localhost:8787',
        )!.relayBase,
        Uri.parse('wss://localhost:8787'),
      );
      // http means an unencrypted dev relay, and says so.
      expect(
        CoworkPairingInvite.tryParse(
          'cowork://pair?c=$channel&k=1&r=http://127.0.0.1:8000',
        )!.relayBase,
        Uri.parse('ws://127.0.0.1:8000'),
      );
    });

    test('a host that prints the whole code in k is accepted too', () {
      final invite = CoworkPairingInvite.tryParse(
        'cowork://pair?c=$channel&k=$channel-428913',
      );

      expect(invite!.pairingChannel, channel);
      expect(invite.pairingCode, '$channel-428913');
      expect(invite.codeDigits, '428913');
    });

    test('all three forms of the same invite resolve identically', () {
      // A scan, a paste with the banner text around it, and a typed code.
      final scanned = CoworkPairingInvite.tryParse(
        'cowork://pair?c=$channel&k=428913',
      );
      final pasted = CoworkPairingInvite.tryParse(
        'Scan this, or type the code:\n'
        '  cowork://pair?c=$channel&k=428913  \n'
        'It expires in five minutes.',
      );
      final typed = CoworkPairingInvite.tryParse('$channel-428913');

      expect(pasted, scanned);
      expect(typed, scanned);
    });

    test('the typed code carries its own channel', () {
      // §15: the pairing code IS the channel id plus the digits, which is why
      // typing it needs nothing the QR has (bead cowork-b75, resolved).
      final invite = CoworkPairingInvite.tryParse('  $channel-428913 ');

      expect(invite!.pairingChannel, channel);
      expect(invite.pairingCode, '$channel-428913');
      expect(invite.relayBase, Uri.parse(kDefaultCoworkRelayBase));
    });

    test('a malformed invite is null, never a half-built connection', () {
      final cases = <String>[
        '',
        '   ',
        'cowork://pair', // no channel, no code
        'cowork://pair?c=$channel', // no code
        'cowork://pair?k=428913', // no channel
        'cowork://elsewhere?c=$channel&k=1', // not the pairing action
        'cowork://pair?c=$channel&k=1&r=ftp://api.chuk.chat', // not a socket
        'https://example.test/promo', // a QR code from a poster
        'not a uri and not a code',
        'cowork://pair?c=$channel&k=other-428913', // a code for another channel
        'cowork://pair?c=has-a-dash&k=428913', // c must not carry the dash
        '-428913', // empty channel
        '$channel-', // empty digits
      ];

      for (final raw in cases) {
        expect(
          CoworkPairingInvite.tryParse(raw),
          isNull,
          reason: 'should not parse: $raw',
        );
      }
    });

    test('round-trips through the URI the host prints', () {
      final invite = CoworkPairingInvite.tryParse(
        'cowork://pair?c=$channel&k=428913&r=wss://relay.example.test',
      )!;

      expect(CoworkPairingInvite.tryParse(invite.toUri().toString()), invite);
    });

    test('toString leaks neither the channel nor the code', () {
      final invite = CoworkPairingInvite.tryParse(
        'cowork://pair?c=$channel&k=428913',
      )!;

      expect(invite.toString(), isNot(contains(channel)));
      expect(invite.toString(), isNot(contains('428913')));
    });
  });
}
