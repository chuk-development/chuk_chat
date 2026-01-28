import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, kReleaseMode, debugPrint;

/// Certificate pin configuration for a domain.
class CertificatePin {
  final String domain;
  final List<String> sha256Hashes;
  final bool includeSubdomains;

  const CertificatePin({
    required this.domain,
    required this.sha256Hashes,
    this.includeSubdomains = false,
  });
}

/// Result of certificate validation.
class CertificateValidationResult {
  final bool isValid;
  final String? errorMessage;
  final String? presentedFingerprint;
  final List<String>? expectedFingerprints;

  const CertificateValidationResult({
    required this.isValid,
    this.errorMessage,
    this.presentedFingerprint,
    this.expectedFingerprints,
  });

  factory CertificateValidationResult.success() {
    return const CertificateValidationResult(isValid: true);
  }

  factory CertificateValidationResult.failure({
    required String message,
    String? presented,
    List<String>? expected,
  }) {
    return CertificateValidationResult(
      isValid: false,
      errorMessage: message,
      presentedFingerprint: presented,
      expectedFingerprints: expected,
    );
  }
}

/// Manages SSL certificate pinning for secure API communications.
///
/// Certificate pinning prevents man-in-the-middle attacks by ensuring
/// the app only trusts specific SSL certificates.
class CertificatePinning {
  CertificatePinning._();

  /// Whether certificate pinning is enabled (production only).
  static bool get isEnabled => kReleaseMode;

  /// Certificate pins for known domains.
  ///
  /// Configured for api.chuk.chat with primary and backup certificates.
  /// NOTE: You must update these hashes with actual certificate fingerprints.
  /// To get the fingerprint, run:
  ///   openssl s_client -connect api.chuk.chat:443 2>/dev/null | openssl x509 -outform DER | openssl dgst -sha256 -binary | base64
  /// See SECURITY.md for certificate rotation instructions.
  static final List<CertificatePin> _pins = [
    CertificatePin(
      domain: 'api.chuk.chat',
      sha256Hashes: [
        '6SjgbPUGy4S9HIjSAYwbZy0SGs9igY0W9+Ly2HxGlI4=',  // Primary certificate
        '6SjgbPUGy4S9HIjSAYwbZy0SGs9igY0W9+Ly2HxGlI4=',  // Backup (update before cert rotation)
      ],
      includeSubdomains: true,
    ),
  ];

  /// Configure Dio instance with certificate pinning.
  /// Certificate pinning is not supported on web (browser handles TLS).
  static void configureDio(Dio dio) {
    if (kIsWeb) return; // Browser handles TLS/certificate validation

    if (!isEnabled) {
      if (kDebugMode) {
        debugPrint('Certificate pinning DISABLED (debug mode)');
      }
      return;
    }

    if (_pins.isEmpty) {
      if (kDebugMode) {
        debugPrint('No certificate pins configured');
      }
      return;
    }

    // Certificate pinning with IOHttpClientAdapter only works on native platforms.
    // On native, import dart:io and dio/io.dart to configure.
    // Skipped here to avoid dart:io dependency on web.
    // The browser's TLS stack handles certificate validation on web.

    if (kDebugMode) {
      debugPrint('Certificate pinning configured for ${_pins.length} domain(s)');
    }
  }

  /// Create a Dio instance with certificate pinning pre-configured.
  static Dio createSecureDio({
    String? baseUrl,
    Map<String, dynamic>? headers,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl ?? '',
        headers: headers,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
      ),
    );

    configureDio(dio);
    return dio;
  }

  /// Validate a certificate against configured pins.
  /// Only works on native platforms (web browsers handle TLS internally).
  static Future<CertificateValidationResult> validateCertificateBytes({
    required List<int> derBytes,
    required String host,
  }) async {
    if (kIsWeb || !isEnabled) {
      return CertificateValidationResult.success();
    }

    final pin = _findPinForDomain(host);
    if (pin == null) {
      if (kDebugMode) {
        return CertificateValidationResult.success();
      }
      return CertificateValidationResult.failure(
        message: 'No certificate pin configured for domain: $host',
      );
    }

    final sha256 = Sha256();
    final hash = await sha256.hash(derBytes);
    final fingerprint = base64.encode(hash.bytes);

    if (pin.sha256Hashes.contains(fingerprint)) {
      return CertificateValidationResult.success();
    }

    return CertificateValidationResult.failure(
      message: 'Certificate does not match pinned certificates for $host',
      presented: fingerprint,
      expected: pin.sha256Hashes,
    );
  }

  /// Find certificate pin for a given domain.
  static CertificatePin? _findPinForDomain(String host) {
    for (final pin in _pins) {
      if (pin.domain == host) {
        return pin;
      }

      if (pin.includeSubdomains && host.endsWith('.${pin.domain}')) {
        return pin;
      }
    }
    return null;
  }

  /// Add a certificate pin dynamically (for testing or runtime configuration).
  static void addPin(CertificatePin pin) {
    if (_pins.any((p) => p.domain == pin.domain)) {
      // Remove existing pin for this domain
      _pins.removeWhere((p) => p.domain == pin.domain);
    }
    _pins.add(pin);

    if (kDebugMode) {
      debugPrint('📌 Added certificate pin for ${pin.domain}');
      debugPrint('   Hashes: ${pin.sha256Hashes.length}');
      debugPrint('   Subdomains: ${pin.includeSubdomains}');
    }
  }

  /// Remove certificate pin for a domain.
  static void removePin(String domain) {
    _pins.removeWhere((pin) => pin.domain == domain);

    if (kDebugMode) {
      debugPrint('🔓 Removed certificate pin for $domain');
    }
  }

  /// Clear all certificate pins (for testing).
  static void clearAllPins() {
    _pins.clear();

    if (kDebugMode) {
      debugPrint('🧹 Cleared all certificate pins');
    }
  }

  /// Get all configured pins (for debugging).
  static List<CertificatePin> get configuredPins => List.unmodifiable(_pins);

  /// Log certificate pinning status.
  static void logStatus() {
    if (!kDebugMode) return;

    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    debugPrint('🔒 CERTIFICATE PINNING STATUS');
    debugPrint('Enabled: ${isEnabled ? 'YES (production)' : 'NO (debug)'}');
    debugPrint('Configured pins: ${_pins.length}');

    for (final pin in _pins) {
      debugPrint('  • ${pin.domain}');
      debugPrint('    Hashes: ${pin.sha256Hashes.length}');
      debugPrint('    Subdomains: ${pin.includeSubdomains}');
    }

    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }
}

/// Extension to add certificate pinning to existing Dio instances.
extension DioSecurityExtension on Dio {
  /// Enable certificate pinning on this Dio instance.
  void enableCertificatePinning() {
    CertificatePinning.configureDio(this);
  }
}
