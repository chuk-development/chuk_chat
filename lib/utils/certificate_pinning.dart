import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, kReleaseMode, debugPrint;

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
///
/// Pinning is enforced in release builds on native platforms (Android,
/// iOS, Linux, macOS, Windows). In debug mode it is disabled to allow
/// proxy tools like Charles/mitmproxy. On web, the browser handles TLS.
///
/// To update pins after certificate rotation:
///   openssl s_client -connect api.chuk.chat:443 2>/dev/null \
///     | openssl x509 -outform DER | openssl dgst -sha256 -binary | base64
class CertificatePinning {
  CertificatePinning._();

  /// Whether certificate pinning is enabled (production only).
  static bool get isEnabled => kReleaseMode;

  /// IO-level Dio configurator. Set by [registerNativeConfigurator] from
  /// platform-specific bootstrap code. On web this stays null (no-op).
  static void Function(Dio dio, List<CertificatePin> pins)? _nativeConfigurator;

  /// Register the native (dart:io) Dio configurator.
  /// Called once during app startup from non-web code.
  static void registerNativeConfigurator(
    void Function(Dio dio, List<CertificatePin> pins) configurator,
  ) {
    _nativeConfigurator = configurator;
  }

  /// Certificate pins for known domains.
  ///
  /// Pin both the leaf certificate AND the intermediate CA so that
  /// a leaf-cert rotation doesn't immediately brick the app — the
  /// intermediate pin acts as a grace-period backup.
  static final List<CertificatePin> _pins = [
    CertificatePin(
      domain: 'api.chuk.chat',
      sha256Hashes: [
        'KmvfH2LK5C+SyrlN/6GezJzEQ0JHBMRgDkfPxpp5tGU=', // Leaf certificate
        'HfwWBfutNY2LyET3bRUgP6ycpcGnn9SFf/ryhk++v5Y=', // Intermediate CA (backup)
      ],
      includeSubdomains: true,
    ),
  ];

  /// Configure Dio instance with certificate pinning.
  ///
  /// On native platforms in release mode, installs a
  /// badCertificateCallback that validates the server certificate's
  /// SHA-256 fingerprint against [_pins]. On web or debug mode: no-op.
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

    if (_nativeConfigurator != null) {
      _nativeConfigurator!(dio, _pins);
      if (kDebugMode) {
        debugPrint(
          'Certificate pinning ENFORCED for ${_pins.length} domain(s)',
        );
      }
    } else {
      // On native platforms in release mode, a missing configurator means
      // pinning was expected but won't be applied. Throw to avoid silent
      // downgrade to unpinned connections. (Web is already excluded above.)
      throw StateError(
        'Certificate pinning: native configurator not registered. '
        'Call registerNativeConfigurator() during app startup.',
      );
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

  /// Validate a certificate's DER bytes against configured pins.
  static Future<CertificateValidationResult> validateCertificateBytes({
    required List<int> derBytes,
    required String host,
  }) async {
    if (kIsWeb || !isEnabled) {
      return CertificateValidationResult.success();
    }

    final pin = findPinForDomain(host);
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
  static CertificatePin? findPinForDomain(String host) {
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

  /// Get all configured pins.
  static List<CertificatePin> get configuredPins => List.unmodifiable(_pins);

  /// Add a certificate pin dynamically (for testing or runtime configuration).
  static void addPin(CertificatePin pin) {
    if (_pins.any((p) => p.domain == pin.domain)) {
      _pins.removeWhere((p) => p.domain == pin.domain);
    }
    _pins.add(pin);

    if (kDebugMode) {
      debugPrint('Added certificate pin for ${pin.domain}');
      debugPrint('   Hashes: ${pin.sha256Hashes.length}');
      debugPrint('   Subdomains: ${pin.includeSubdomains}');
    }
  }

  /// Remove certificate pin for a domain.
  static void removePin(String domain) {
    _pins.removeWhere((pin) => pin.domain == domain);

    if (kDebugMode) {
      debugPrint('Removed certificate pin for $domain');
    }
  }

  /// Clear all certificate pins (for testing).
  static void clearAllPins() {
    _pins.clear();

    if (kDebugMode) {
      debugPrint('Cleared all certificate pins');
    }
  }

  /// Log certificate pinning status.
  static void logStatus() {
    if (!kDebugMode) return;

    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    debugPrint('CERTIFICATE PINNING STATUS');
    debugPrint('Enabled: ${isEnabled ? 'YES (production)' : 'NO (debug)'}');
    debugPrint('Configured pins: ${_pins.length}');

    for (final pin in _pins) {
      debugPrint('  - ${pin.domain}');
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
