// lib/services/network_status_service.dart
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Provides utilities for checking general internet reachability.
///
/// Uses a lenient approach to avoid false "offline" states on slow connections:
/// - Probes run in parallel for faster detection
/// - Requires multiple consecutive failures before declaring offline
/// - Longer timeouts to accommodate slow mobile networks (4G/3G)
class NetworkStatusService {
  // Generous timeouts for slow mobile networks
  static const Duration _defaultTimeout = Duration(seconds: 10);
  static const Duration _quickTimeout = Duration(seconds: 6);
  static const Duration _perProbeTimeout = Duration(seconds: 8);

  // Require consecutive failures before declaring offline
  static int _consecutiveFailures = 0;
  static const int _failuresRequiredForOffline = 2;

  static final List<_ConnectivityProbe> _probes = <_ConnectivityProbe>[
    _ConnectivityProbe(
      uri: Uri.parse(
        'https://cloudflare-dns.com/dns-query?name=cloudflare.com&type=A',
      ),
      headers: {'accept': 'application/dns-json'},
      expectedStatusCodes: {200},
    ),
    _ConnectivityProbe(
      uri: Uri.parse('https://www.google.com/generate_204'),
      expectedStatusCodes: {204},
    ),
    _ConnectivityProbe(
      uri: Uri.parse('https://1.1.1.1/cdn-cgi/trace'),
      expectedStatusCodes: {200},
    ),
  ];

  // Reactive state for network status
  static final ValueNotifier<bool> _isOnlineNotifier = ValueNotifier<bool>(true);
  static ValueListenable<bool> get isOnlineListenable => _isOnlineNotifier;
  static bool get isOnline => _isOnlineNotifier.value;

  // Cache last check time to avoid hammering network
  static DateTime? _lastCheckTime;
  static bool? _lastCheckResult;
  static const Duration _cacheValidDuration = Duration(seconds: 10);

  /// Returns `true` when at least one probe succeeds within the timeout.
  /// Uses parallel probing for faster detection on slow networks.
  static Future<bool> hasInternetConnection({
    Duration timeout = _defaultTimeout,
    bool useCache = true,
  }) async {
    // Use cached result if available and fresh
    if (useCache && _lastCheckResult != null && _lastCheckTime != null) {
      final timeSinceLastCheck = DateTime.now().difference(_lastCheckTime!);
      if (timeSinceLastCheck < _cacheValidDuration) {
        return _lastCheckResult!;
      }
    }

    // Run all probes in parallel - first success wins
    final result = await _checkWithParallelProbes(timeout);

    _lastCheckResult = result;
    _lastCheckTime = DateTime.now();

    if (result) {
      _consecutiveFailures = 0;
      _updateStatus(true);
    } else {
      _consecutiveFailures++;
      // Only declare offline after consecutive failures
      if (_consecutiveFailures >= _failuresRequiredForOffline) {
        _updateStatus(false);
      }
      // If we haven't hit the threshold yet, don't change status
      // This prevents brief slowdowns from triggering offline
    }

    return result;
  }

  /// Run probes in parallel - returns true if ANY probe succeeds
  static Future<bool> _checkWithParallelProbes(Duration overallTimeout) async {
    final completer = Completer<bool>();
    int completedProbes = 0;
    final totalProbes = _probes.length;

    // Start all probes in parallel
    for (final probe in _probes) {
      _checkSingleProbe(probe).then((success) {
        if (completer.isCompleted) return;

        if (success) {
          // First success - we're online!
          completer.complete(true);
        } else {
          completedProbes++;
          // All probes failed
          if (completedProbes >= totalProbes) {
            completer.complete(false);
          }
        }
      });
    }

    // Overall timeout fallback
    return completer.future.timeout(
      overallTimeout,
      onTimeout: () => false,
    );
  }

  /// Check a single probe with its own timeout
  static Future<bool> _checkSingleProbe(_ConnectivityProbe probe) async {
    try {
      final response = await http
          .get(probe.uri, headers: probe.headers)
          .timeout(_perProbeTimeout);
      return probe.expectedStatusCodes.contains(response.statusCode);
    } on TimeoutException catch (_) {
      return false;
    } on Exception catch (_) {
      return false;
    }
  }

  /// Quick check with moderate timeout - still lenient for slow networks
  static Future<bool> quickCheck() async {
    return hasInternetConnection(timeout: _quickTimeout, useCache: false);
  }

  /// Update the network status notifier
  static void _updateStatus(bool isOnline) {
    if (_isOnlineNotifier.value != isOnline) {
      _isOnlineNotifier.value = isOnline;
      debugPrint('Network status changed: ${isOnline ? 'ONLINE' : 'OFFLINE'}');
    }
  }

  /// Reset consecutive failure count (call when user initiates action)
  static void resetFailureCount() {
    _consecutiveFailures = 0;
  }

  /// Manually set offline (for testing or explicit offline mode)
  static void setOffline() {
    _updateStatus(false);
  }

  /// Manually set online (for testing)
  static void setOnline() {
    _updateStatus(true);
  }

  /// Determine if an error is likely a network error vs auth error
  static bool isNetworkError(dynamic error) {
    if (error == null) return false;

    final String errorStr = error.toString().toLowerCase();

    // Common network error patterns
    return errorStr.contains('socketexception') ||
           errorStr.contains('failed host lookup') ||
           errorStr.contains('network is unreachable') ||
           errorStr.contains('connection refused') ||
           errorStr.contains('connection timed out') ||
           errorStr.contains('no route to host') ||
           errorStr.contains('network error') ||
           errorStr.contains('timeout');
  }
}

class _ConnectivityProbe {
  final Uri uri;
  final Map<String, String>? headers;
  final Set<int> expectedStatusCodes;

  const _ConnectivityProbe({
    required this.uri,
    this.headers,
    required this.expectedStatusCodes,
  });
}
