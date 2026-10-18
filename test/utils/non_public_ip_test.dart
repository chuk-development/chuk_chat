// Unit tests for the shared non-public IP rule
// (`lib/utils/non_public_ip.dart`): the addresses a model-supplied URL must
// never make the app connect to.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/non_public_ip.dart';

List<int> _v4(String a, String b, String c, String d) => [
  int.parse(a),
  int.parse(b),
  int.parse(c),
  int.parse(d),
];

List<int> _v6(List<int> bytes) => bytes;

void main() {
  group('isNonPublicIp', () {
    test('public IPv4 stays public', () {
      expect(isNonPublicIp(_v4('93', '184', '216', '34')), isFalse);
      expect(isNonPublicIp(_v4('8', '8', '8', '8')), isFalse);
      expect(isNonPublicIp(_v4('1', '1', '1', '1')), isFalse);
      expect(isNonPublicIp(_v4('172', '15', '0', '1')), isFalse);
      expect(isNonPublicIp(_v4('172', '32', '0', '1')), isFalse);
      expect(isNonPublicIp(_v4('192', '169', '0', '1')), isFalse);
      expect(isNonPublicIp(_v4('100', '63', '0', '1')), isFalse);
    });

    test('private, loopback and reserved IPv4 is refused', () {
      expect(isNonPublicIp(_v4('127', '0', '0', '1')), isTrue);
      expect(isNonPublicIp(_v4('10', '0', '0', '1')), isTrue);
      expect(isNonPublicIp(_v4('172', '16', '0', '1')), isTrue);
      expect(isNonPublicIp(_v4('172', '31', '255', '255')), isTrue);
      expect(isNonPublicIp(_v4('192', '168', '1', '1')), isTrue);
      expect(isNonPublicIp(_v4('169', '254', '1', '1')), isTrue);
      expect(isNonPublicIp(_v4('0', '0', '0', '0')), isTrue);
      expect(isNonPublicIp(_v4('100', '64', '0', '1')), isTrue); // CGNAT
      expect(isNonPublicIp(_v4('100', '127', '255', '255')), isTrue);
      expect(isNonPublicIp(_v4('198', '18', '0', '1')), isTrue);
      expect(isNonPublicIp(_v4('224', '0', '0', '1')), isTrue); // multicast
      expect(isNonPublicIp(_v4('255', '255', '255', '255')), isTrue);
    });

    test('IPv4-mapped and compatible IPv6 unwraps to the IPv4 rule', () {
      // ::ffff:127.0.0.1
      final List<int> mapped = <int>[
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1,
      ];
      expect(isNonPublicIp(mapped), isTrue);
      // ::ffff:8.8.8.8
      final List<int> mappedPublic = <int>[
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 8, 8, 8, 8,
      ];
      expect(isNonPublicIp(mappedPublic), isFalse);
    });

    test('NAT64 and 6to4 embedded IPv4 is caught', () {
      // 64:ff9b::127.0.0.1 — bytes: 00 64 | ff 9b | 8× 00 | IPv4
      final List<int> nat64 = <int>[
        0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1,
      ];
      expect(isNonPublicIp(nat64), isTrue);
      // 2002:0a00:0001:: = 2002:10.0.0.1
      final List<int> sixTo4 = <int>[
        0x20, 0x02, 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ];
      expect(isNonPublicIp(sixTo4), isTrue);
      // 2002:0808:0808:: = 2002:8.8.8.8 stays public.
      final List<int> sixTo4Public = <int>[
        0x20, 0x02, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ];
      expect(isNonPublicIp(sixTo4Public), isFalse);
    });

    test('IPv6 loopback, unique local, link-local and multicast is refused', () {
      expect(isNonPublicIp(_v6(List<int>.filled(16, 0)..[15] = 1)), isTrue); // ::1
      expect(isNonPublicIp(_v6(<int>[0xfc, 0, ...List<int>.filled(14, 0)])), isTrue);
      expect(isNonPublicIp(_v6(<int>[0xfe, 0x80, ...List<int>.filled(14, 1)])), isTrue);
      expect(isNonPublicIp(_v6(<int>[0xfe, 0xc0, ...List<int>.filled(14, 1)])), isTrue);
      expect(isNonPublicIp(_v6(<int>[0xff, 0x02, ...List<int>.filled(14, 1)])), isTrue);
      // A global unicast address stays public (2001:db8:: is doc range, but
      // by prefix it is neither ULA, link-local nor multicast).
      expect(
        isNonPublicIp(_v6(<int>[0x26, 0x07, ...List<int>.filled(14, 1)])),
        isFalse,
      );
    });

    test('unknown length is refused', () {
      expect(isNonPublicIp(<int>[1, 2, 3]), isTrue);
      expect(isNonPublicIp(<int>[]), isTrue);
    });
  });
}
