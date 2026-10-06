// lib/utils/host_lookup_io.dart
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The IP addresses [host] resolves to, as text.
Future<List<String>> lookupHostAddresses(String host) async {
  final addresses = await InternetAddress.lookup(host);
  return [for (final a in addresses) a.address];
}

/// An HTTP client that connects only to addresses [isNonPublic] accepts.
///
/// The check runs inside the connection: the name is resolved once, the
/// answer is checked, and the socket opens to exactly that address. A name
/// that answers public for a pre-check and private for the real request
/// (DNS rebinding) cannot slip through. TLS still verifies the certificate
/// against the host name.
http.Client? publicOnlyHttpClient(bool Function(List<int> ip) isNonPublic) {
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 15)
    ..connectionFactory = (uri, proxyHost, proxyPort) async {
      final addresses = await InternetAddress.lookup(uri.host);
      if (addresses.isEmpty ||
          addresses.any((a) => isNonPublic(a.rawAddress))) {
        throw const SocketException('local address not allowed');
      }
      final task = await Socket.startConnect(addresses.first, uri.port);
      if (uri.scheme != 'https') return task;
      return ConnectionTask.fromSocket(
        task.socket.then((s) => SecureSocket.secure(s, host: uri.host)),
        task.cancel,
      );
    };
  return IOClient(client);
}
