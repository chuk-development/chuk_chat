import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_location.dart';

Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  test('granted: answers lat, lon and accuracy_m', () async {
    final VoiceLocationResolver resolver = VoiceLocationResolver(
      checkPermission: () async => VoiceLocationPermission.granted,
      fetch: () async => <String, dynamic>{
        'success': true,
        'latitude': 54.32,
        'longitude': 10.13,
        'accuracy': 12.5,
        'altitude': 3.0,
      },
    );
    expect(_json(await resolver.answer()), <String, dynamic>{
      'lat': 54.32,
      'lon': 10.13,
      'accuracy_m': 12.5,
    });
  });

  test('denied: asks once per call, then answers without a prompt', () async {
    int fetches = 0;
    final VoiceLocationResolver resolver = VoiceLocationResolver(
      checkPermission: () async => VoiceLocationPermission.denied,
      fetch: () async {
        fetches++; // DeviceServices asks here; the user refuses.
        return <String, dynamic>{
          'success': false,
          'error': 'Location permission denied by user',
        };
      },
    );
    expect(_json(await resolver.answer()), <String, dynamic>{
      'error': 'permission denied',
    });
    expect(_json(await resolver.answer()), <String, dynamic>{
      'error': 'permission denied',
    });
    expect(fetches, 1, reason: 'no second system prompt in the same call');

    resolver.resetForNewCall();
    await resolver.answer();
    expect(fetches, 2, reason: 'a new call may ask again');
  });

  test('denied, then granted at the prompt: answers the position', () async {
    final VoiceLocationResolver resolver = VoiceLocationResolver(
      checkPermission: () async => VoiceLocationPermission.denied,
      fetch: () async => <String, dynamic>{
        'success': true,
        'latitude': 1,
        'longitude': 2,
        'accuracy': 3,
      },
    );
    expect(_json(await resolver.answer())['lat'], 1);
  });

  test('denied for good: no prompt, permission denied', () async {
    int fetches = 0;
    final VoiceLocationResolver resolver = VoiceLocationResolver(
      checkPermission: () async => VoiceLocationPermission.deniedForever,
      fetch: () async {
        fetches++;
        return <String, dynamic>{};
      },
    );
    expect(_json(await resolver.answer()), <String, dynamic>{
      'error': 'permission denied',
    });
    expect(fetches, 0);
  });

  test('no location on this platform: not available', () async {
    final VoiceLocationResolver resolver = VoiceLocationResolver(
      checkPermission: () async => VoiceLocationPermission.unavailable,
      fetch: () async => throw StateError('must not be called'),
    );
    expect(_json(await resolver.answer()), <String, dynamic>{
      'error': 'not available',
    });
  });

  test(
    'other failures pass their reason, throws become a plain error',
    () async {
      final VoiceLocationResolver off = VoiceLocationResolver(
        checkPermission: () async => VoiceLocationPermission.granted,
        fetch: () async => <String, dynamic>{
          'success': false,
          'error': 'Location services are disabled on this device',
        },
      );
      expect(
        _json(await off.answer())['error'],
        'Location services are disabled on this device',
      );

      final VoiceLocationResolver broken = VoiceLocationResolver(
        checkPermission: () async => VoiceLocationPermission.granted,
        fetch: () async => throw StateError('timeout'),
      );
      expect(_json(await broken.answer()), <String, dynamic>{
        'error': 'location unavailable',
      });
    },
  );
}
