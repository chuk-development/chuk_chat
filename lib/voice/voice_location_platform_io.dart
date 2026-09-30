// lib/voice/voice_location_platform_io.dart
//
// Native: the permission check straight from geolocator (no prompt), and the
// fix from the app's one location path, DeviceServices.getCurrentLocation
// (which asks when access is not granted yet).

import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart';

import 'package:chuk_chat/services/device_services.dart';
import 'package:chuk_chat/voice/voice_location.dart';

Future<VoiceLocationPermission> checkLocationPermission() async {
  // DeviceServices has no GPS on the Linux/Windows desktop.
  if (Platform.isLinux || Platform.isWindows) {
    return VoiceLocationPermission.unavailable;
  }
  final LocationPermission permission = await Geolocator.checkPermission();
  return switch (permission) {
    LocationPermission.always ||
    LocationPermission.whileInUse => VoiceLocationPermission.granted,
    LocationPermission.deniedForever => VoiceLocationPermission.deniedForever,
    LocationPermission.unableToDetermine ||
    LocationPermission.denied => VoiceLocationPermission.denied,
  };
}

Future<Map<String, dynamic>> fetchCurrentLocation() =>
    DeviceServices().getCurrentLocation();
