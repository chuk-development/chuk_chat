// lib/services/network_status_service.dart
import 'dart:async';
import 'package:http/http.dart' as http;

/// Provides utilities for checking general internet reachability.
class NetworkStatusService {
  static const Duration _defaultTimeout = Duration(seconds: 4);

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

  /// Returns `true` when at least one probe succeeds within the timeout.
  static Future<bool> hasInternetConnection({
    Duration timeout = _defaultTimeout,
  }) async {
    for (final _ConnectivityProbe probe in _probes) {
      try {
        final http.Response response = await http
            .get(probe.uri, headers: probe.headers)
            .timeout(timeout);
        if (probe.expectedStatusCodes.contains(response.statusCode)) {
          return true;
        }
      } on TimeoutException catch (_) {
        // Try the next probe.
      } on Exception catch (_) {
        // Try the next probe.
      }
    }
    return false;
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
