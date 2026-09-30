// lib/voice/voice_location.dart
//
// The `get_location` answer for the voice worker: a foreground position from
// the app's existing geolocator path (`DeviceServices.getCurrentLocation`),
// with at most one system permission prompt per call.
//
// Privacy: the position goes to the worker in the RPC answer only. It is
// never logged.

import 'dart:convert';

import 'package:chuk_chat/voice/voice_location_platform_stub.dart'
    if (dart.library.io) 'package:chuk_chat/voice/voice_location_platform_io.dart'
    as platform;
import 'package:chuk_chat/voice/voice_protocol.dart';

/// What the OS says about location access, before asking.
enum VoiceLocationPermission {
  granted,

  /// Not granted yet; asking shows the system prompt.
  denied,

  /// Refused for good; only the settings can change it.
  deniedForever,

  /// No location on this platform (Linux/Windows desktop, web).
  unavailable,
}

class VoiceLocationResolver {
  VoiceLocationResolver({
    Future<VoiceLocationPermission> Function()? checkPermission,
    Future<Map<String, dynamic>> Function()? fetch,
  }) : _check = checkPermission ?? platform.checkLocationPermission,
       _fetch = fetch ?? platform.fetchCurrentLocation;

  final Future<VoiceLocationPermission> Function() _check;

  /// Returns the DeviceServices map: `{success, latitude, longitude,
  /// accuracy}` or `{success: false, error}`. May show the system prompt.
  final Future<Map<String, dynamic>> Function() _fetch;

  bool _askedThisCall = false;

  static String permissionDenied() =>
      jsonEncode(<String, dynamic>{'error': 'permission denied'});

  /// Forget that this call already asked; call when a new call starts.
  void resetForNewCall() => _askedThisCall = false;

  /// The RPC answer: `{"lat", "lon", "accuracy_m"}` or `{"error": ...}`.
  Future<String> answer() async {
    final VoiceLocationPermission permission;
    try {
      permission = await _check();
    } catch (_) {
      return _error('location unavailable');
    }
    switch (permission) {
      case VoiceLocationPermission.unavailable:
        return VoiceProtocol.notAvailable();
      case VoiceLocationPermission.deniedForever:
        return permissionDenied();
      case VoiceLocationPermission.denied:
        // The fetch below asks. Mid-call that prompt is shown once; after a
        // refusal the agent gets the answer without another prompt.
        if (_askedThisCall) return permissionDenied();
        _askedThisCall = true;
      case VoiceLocationPermission.granted:
        break;
    }

    final Map<String, dynamic> result;
    try {
      result = await _fetch();
    } catch (_) {
      return _error('location unavailable');
    }
    if (result['success'] == true) {
      final Object? lat = result['latitude'];
      final Object? lon = result['longitude'];
      final Object? accuracy = result['accuracy'];
      if (lat is num && lon is num) {
        return jsonEncode(<String, dynamic>{
          'lat': lat,
          'lon': lon,
          'accuracy_m': accuracy is num ? accuracy : null,
        });
      }
      return _error('location unavailable');
    }
    final String message = result['error']?.toString() ?? '';
    if (message.toLowerCase().contains('permission')) {
      return permissionDenied();
    }
    return _error(
      message.isEmpty ? 'location unavailable' : truncateRunes(message, 200),
    );
  }

  static String _error(String message) =>
      jsonEncode(<String, dynamic>{'error': message});
}
