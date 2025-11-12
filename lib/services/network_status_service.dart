// lib/services/network_status_service.dart
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Provides utilities for checking general internet reachability.
class NetworkStatusService {
  static const Duration _defaultTimeout = Duration(seconds: 4);
  static const Duration _quickTimeout = Duration(seconds: 2);

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
  static const Duration _cacheValidDuration = Duration(seconds: 5);

  /// Returns `true` when at least one probe succeeds within the timeout.
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

    final DateTime deadline = DateTime.now().add(timeout);

    for (final _ConnectivityProbe probe in _probes) {
      final Duration remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        _updateStatus(false);
        _lastCheckResult = false;
        _lastCheckTime = DateTime.now();
        return false;
      }

      try {
        final http.Response response = await http
            .get(probe.uri, headers: probe.headers)
            .timeout(remaining);
        if (probe.expectedStatusCodes.contains(response.statusCode)) {
          _updateStatus(true);
          _lastCheckResult = true;
          _lastCheckTime = DateTime.now();
          return true;
        }
      } on TimeoutException catch (_) {
        // Try the next probe.
      } on Exception catch (_) {
        // Try the next probe.
      }
    }

    _updateStatus(false);
    _lastCheckResult = false;
    _lastCheckTime = DateTime.now();
    return false;
  }

  /// Quick check with shorter timeout (2 seconds)
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
