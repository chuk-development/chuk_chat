// lib/utils/certificate_pinning_register_io.dart
//
// Native (dart:io) platform — registers the real certificate pinning
// configurator that sets badCertificateCallback on Dio's HttpClient,
// and installs an HttpOverrides on Windows to work around missing system
// CA certificates in the Dart runtime.

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/utils/certificate_pinning.dart';
import 'package:chuk_chat/utils/certificate_pinning_io.dart' as pinning_io;

/// Trusted public API hosts used by built-in tools (weather, maps, etc.).
/// Certificate verification failures for these hosts are accepted on Windows
/// because the Dart runtime sometimes cannot access the Windows system
/// certificate store. Only well-known public services are listed here.
const Set<String> _trustedToolApiHosts = {
  // Open-Meteo (weather)
  'api.open-meteo.com',
  'geocoding-api.open-meteo.com',
  // OpenStreetMap / Nominatim (maps, geocoding)
  'nominatim.openstreetmap.org',
  // OSRM (routing)
  'router.workspace-osrm.org',
  // Yahoo Finance (stock data — behind feature flag, but kept for future use)
  'query1.finance.yahoo.com',
};

/// [HttpOverrides] that accepts certificates for known trusted public API
/// hosts when the standard verification fails. Installed only on Windows
/// where the Dart runtime sometimes fails to verify certificates against
/// the system store.
///
/// Risk-accepted: This bypasses full chain-of-trust validation for the listed
/// hosts. We still verify that the certificate is within its validity period
/// to reject obviously bogus or expired certs. A proper fix would bundle
/// CA root certificates, but that requires ongoing maintenance. These are
/// all public, well-known HTTPS services; the risk is acceptable for the
/// data they serve (weather, maps, geocoding).
class _WindowsCertOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
          if (!_trustedToolApiHosts.contains(host)) {
            return false;
          }
          // Reject expired or not-yet-valid certificates.
          final now = DateTime.now();
          if (cert.endValidity.isBefore(now) ||
              cert.startValidity.isAfter(now)) {
            return false;
          }
          return true;
        };
    return client;
  }
}

/// Register the native certificate pinning configurator.
/// Must be called once during app startup, before any Dio requests.
void registerCertificatePinning() {
  CertificatePinning.registerNativeConfigurator(
    pinning_io.configureDioWithPinning,
  );

  // On Windows, install HttpOverrides so that package:http Client() can
  // reach trusted public APIs even when the system CA store is unavailable
  // to the Dart VM.
  if (Platform.isWindows) {
    HttpOverrides.global = _WindowsCertOverrides();
    if (kDebugMode) {
      debugPrint(
        '[Cert] Windows HttpOverrides installed for '
        '${_trustedToolApiHosts.length} trusted API hosts',
      );
    }
  }
}
