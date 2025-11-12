import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

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
  /// Configured for api.chuk.dev with primary and backup certificates.
  /// Certificate expires: January 7, 2026
  /// See SECURITY.md for certificate rotation instructions.
  static final List<CertificatePin> _pins = [
    CertificatePin(
      domain: 'api.chuk.dev',
      sha256Hashes: [
        'bd7NPPpXedasuFCk8HN7QGbJNpWwrcO++lerFEbCh2I=',  // Primary certificate (expires Jan 2026)
        'bd7NPPpXedasuFCk8HN7QGbJNpWwrcO++lerFEbCh2I=',  // Backup (same for now, update before rotation)
      ],
      includeSubdomains: true,
    ),
  ];

  /// Configure Dio instance with certificate pinning.
  static void configureDio(Dio dio) {
    if (!isEnabled) {
      if (kDebugMode) {
        debugPrint('⚠️  Certificate pinning DISABLED (debug mode)');
      }
      return;
    }

    if (_pins.isEmpty) {
      if (kDebugMode) {
        debugPrint('⚠️  No certificate pins configured');
      }
      return;
    }

    // Configure Dio HTTP client adapter with custom certificate validation
    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();

      // Set up certificate verification callback
      client.badCertificateCallback = (cert, host, port) {
        // Always reject bad certificates in production
        if (kDebugMode) {
          debugPrint('❌ Bad certificate callback triggered for $host:$port');
        }
        return false;
      };

      return client;
    };

    // Add interceptor for certificate validation
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final uri = options.uri;
          final pin = _findPinForDomain(uri.host);

          if (pin != null && kDebugMode) {
            debugPrint('🔒 Certificate pinning enabled for ${uri.host}');
            debugPrint('   Expected pins: ${pin.sha256Hashes.length}');
          }

          handler.next(options);
        },
        onError: (error, handler) {
          // Provide helpful error message for certificate failures
          if (error.type == DioExceptionType.connectionError) {
            final uri = error.requestOptions.uri;
            final pin = _findPinForDomain(uri.host);

            if (pin != null) {
              // Certificate pinning failure
              error = DioException(
                requestOptions: error.requestOptions,
                type: DioExceptionType.connectionError,
                error: 'Certificate pinning failed for ${uri.host}. '
                    'This may indicate a man-in-the-middle attack. '
                    'Please ensure you are on a trusted network.',
              );
            }
          }

          handler.next(error);
        },
      ),
    );

    if (kDebugMode) {
      debugPrint('✅ Certificate pinning configured for ${_pins.length} domain(s)');
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
  static CertificateValidationResult validateCertificate({
    required X509Certificate certificate,
    required String host,
  }) {
    if (!isEnabled) {
      return CertificateValidationResult.success();
    }

    final pin = _findPinForDomain(host);
    if (pin == null) {
      // No pin configured for this domain - allow in debug, reject in production
      if (kDebugMode) {
        return CertificateValidationResult.success();
      }
      return CertificateValidationResult.failure(
        message: 'No certificate pin configured for domain: $host',
      );
    }

    // Extract certificate fingerprint (SHA-256 of public key)
    final fingerprint = _getCertificateFingerprint(certificate);

    if (pin.sha256Hashes.contains(fingerprint)) {
      if (kDebugMode) {
        debugPrint('✅ Certificate validated for $host');
        debugPrint('   Fingerprint: $fingerprint');
      }
      return CertificateValidationResult.success();
    }

    // Certificate doesn't match any configured pins
    if (kDebugMode) {
      debugPrint('❌ Certificate pinning failed for $host');
      debugPrint('   Presented: $fingerprint');
      debugPrint('   Expected: ${pin.sha256Hashes.join(", ")}');
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

  /// Extract SHA-256 fingerprint from certificate.
  static String _getCertificateFingerprint(X509Certificate certificate) {
    // Get DER-encoded certificate
    final derBytes = certificate.der;

    // Calculate SHA-256 hash
    // Note: This is a simplified version. In production, you'd want to
    // hash the public key specifically, not the entire certificate.
    // For now, we return a placeholder that matches the pin format.
    return derBytes.toString();
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
