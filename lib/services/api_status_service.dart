// lib/services/api_status_service.dart
import 'dart:async';
import 'package:http/http.dart' as http;

/// Utility helpers for checking the availability of the primary API.
class ApiStatusService {
  static const String _defaultBaseUrl = 'https://api.chuk.chat';
  static const Duration _defaultTimeout = Duration(seconds: 4);

  /// Returns `true` when the API responds to either `/health` or a HEAD request
  /// to the root endpoint. Any 2xx-4xx status is treated as "reachable".
  static Future<bool> isApiReachable({
    String? baseUrl,
    Duration timeout = _defaultTimeout,
  }) async {
    final String effectiveBaseUrl = (baseUrl ?? _defaultBaseUrl).trim();
    final Uri healthUri = _buildUri(effectiveBaseUrl, '/health');

    if (await _probe(healthUri, timeout)) {
      return true;
    }

    final Uri rootUri = Uri.parse(effectiveBaseUrl);
    return _probe(rootUri, timeout, method: 'HEAD');
  }

  static Future<bool> _probe(
    Uri uri,
    Duration timeout, {
    String method = 'GET',
  }) async {
    try {
      final http.Response response;
      if (method == 'HEAD') {
        response = await http.head(uri).timeout(timeout);
      } else {
        response = await http.get(uri).timeout(timeout);
      }
      return response.statusCode >= 200 && response.statusCode < 500;
    } on TimeoutException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Uri _buildUri(String base, String path) {
    if (base.endsWith('/')) {
      return Uri.parse(
        '$base${path.startsWith('/') ? path.substring(1) : path}',
      );
    }
    return Uri.parse('$base${path.startsWith('/') ? path : '/$path'}');
  }
}
