// lib/services/websocket_connector_io.dart
//
// Native (dart:io) WebSocket connector with certificate pinning.
// Uses dart:io's WebSocket.connect() with a pinned HttpClient so that
// the same SHA-256 fingerprint validation applied to Dio/HTTP requests
// also protects WebSocket connections.
//
// This file imports dart:io and must NOT be imported on web.

import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:chuk_chat/utils/certificate_pinning.dart';
import 'package:chuk_chat/utils/certificate_pinning_io.dart' as pinning_io;

/// One long-lived pinned [HttpClient] reused across every WebSocket connect.
///
/// The previous code created a fresh client per connect and closed it in a
/// `finally`. That threw away the client's TLS session cache and connection
/// pool every time, so each (re)connect paid a *full* TLS handshake — the
/// dominant, release-only cost behind "the connection takes forever" on
/// mobile, where Doze + network changes force frequent reconnects. Reusing
/// one client lets the TLS layer resume sessions (abbreviated handshake)
/// across reconnects to the same host. The upgraded WebSocket detaches its
/// own socket, so the shared client is safe to keep open and reuse.
HttpClient? _sharedPinnedClient;

/// Create a [WebSocketChannel] with certificate pinning on native platforms.
///
/// In release mode, reuses a pinned [HttpClient] (see [_sharedPinnedClient])
/// so the server certificate is validated against the configured SHA-256
/// pins while TLS sessions survive reconnects. In debug mode, uses the
/// default client (no pinning) to allow proxy tools like Charles/mitmproxy.
Future<WebSocketChannel> connectWebSocket(Uri url) async {
  if (CertificatePinning.isEnabled) {
    final client = _sharedPinnedClient ??= pinning_io.createPinnedHttpClient(
      CertificatePinning.configuredPins,
    );

    final socket = await WebSocket.connect(
      url.toString(),
      customClient: client,
    );

    return IOWebSocketChannel(socket);
  }

  // Debug mode — no pinning, use standard IOWebSocketChannel.connect
  return IOWebSocketChannel.connect(url);
}
