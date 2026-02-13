// lib/utils/certificate_pinning_io.dart
//
// Native-platform certificate pinning implementation.
// Sets badCertificateCallback on Dio's IOHttpClientAdapter to enforce
// SHA-256 fingerprint validation in release builds.
//
// This file imports dart:io and must NOT be imported on web.
// Use conditional imports in consuming code.

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/utils/certificate_pinning.dart';

/// Configure Dio with a [badCertificateCallback] that validates
/// the server certificate against the pinned SHA-256 hashes.
///
/// Called by [CertificatePinning.configureDio] on native platforms
/// when pinning is enabled (release mode).
void configureDioWithPinning(Dio dio, List<CertificatePin> pins) {
  final adapter = dio.httpClientAdapter;
  if (adapter is! IOHttpClientAdapter) {
    // Replace with IOHttpClientAdapter if needed
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        _installBadCertCallback(client, pins);
        return client;
      },
    );
    return;
  }

  // Wrap existing adapter's createHttpClient
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      _installBadCertCallback(client, pins);
      return client;
    },
  );
}

void _installBadCertCallback(HttpClient client, List<CertificatePin> pins) {
  client
      .badCertificateCallback = (X509Certificate cert, String host, int port) {
    // Find pin for this host from the passed list (not the static registry).
    // Use exact match or dot-prefixed subdomain match to prevent bypass
    // (e.g. "evil-api.example.com" must not match "api.example.com").
    final pin = pins.cast<CertificatePin?>().firstWhere(
      (p) => host == p!.domain || host.endsWith('.${p.domain}'),
      orElse: () => null,
    );
    if (pin == null) {
      // No pin configured for this domain — allow (only pinned domains are enforced)
      return true;
    }

    // Compute SHA-256 of the DER-encoded certificate
    final derBytes = cert.der;
    // Use synchronous SHA-256 from dart:io (no async needed)
    final digest = _sha256Sync(derBytes);
    final fingerprint = base64.encode(digest);

    final matches = pin.sha256Hashes.contains(fingerprint);

    if (!matches && kDebugMode) {
      debugPrint('CERTIFICATE PINNING FAILURE');
      debugPrint('  Host: $host:$port');
      debugPrint('  Presented: $fingerprint');
      debugPrint('  Expected: ${pin.sha256Hashes.join(', ')}');
    }

    return matches;
  };
}

/// Synchronous SHA-256 hash.
/// We can't use async crypto in badCertificateCallback,
/// so we use the synchronous `crypto` package.
List<int> _sha256Sync(List<int> data) {
  return crypto.sha256.convert(data).bytes;
}

/// Create an [HttpClient] with certificate pinning configured.
/// Used for WebSocket connections that bypass Dio.
HttpClient createPinnedHttpClient(List<CertificatePin> pins) {
  final client = HttpClient();
  _installBadCertCallback(client, pins);
  return client;
}
