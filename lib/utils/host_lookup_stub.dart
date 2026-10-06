// lib/utils/host_lookup_stub.dart
// Web: no DNS access and no control over the connection.

import 'package:http/http.dart' as http;

/// The IP addresses [host] resolves to, as text. Empty on web.
Future<List<String>> lookupHostAddresses(String host) async => const [];

/// Null on web: the browser opens the connection, so nothing here can hold
/// it to a checked address.
http.Client? publicOnlyHttpClient(bool Function(List<int> ip) isNonPublic) =>
    null;
