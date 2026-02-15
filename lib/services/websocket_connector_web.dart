// lib/services/websocket_connector_web.dart
//
// Web platform WebSocket connector — no certificate pinning.
// The browser's TLS stack handles certificate validation.

import 'package:web_socket_channel/web_socket_channel.dart';

/// Create a [WebSocketChannel] on web.
///
/// Uses the browser's native WebSocket API. Certificate validation
/// is handled by the browser's TLS implementation.
Future<WebSocketChannel> connectWebSocket(Uri url) async {
  return WebSocketChannel.connect(url);
}
