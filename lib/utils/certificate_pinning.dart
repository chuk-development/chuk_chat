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
      // Note: this code path only runs in release mode (isEnabled == true),
      // so kDebugMode is always false here. No debug logging possible.
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

  /// Get all configured pins.
  static List<CertificatePin> get configuredPins => List.unmodifiable(_pins);

}
