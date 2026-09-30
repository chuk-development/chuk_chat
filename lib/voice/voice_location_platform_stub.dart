// lib/voice/voice_location_platform_stub.dart
//
// Web: no location for the voice worker (the call is native-only).

import 'package:chuk_chat/voice/voice_location.dart';

Future<VoiceLocationPermission> checkLocationPermission() async =>
    VoiceLocationPermission.unavailable;

Future<Map<String, dynamic>> fetchCurrentLocation() async => <String, dynamic>{
  'success': false,
  'error': 'not available',
};
